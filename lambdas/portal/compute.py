"""The optional compute instance (the "compute" launch input): any instance type, e.g. a
GPU instance for Parabricks.

Launched in the spoke's private subnet (in local mode, the hub nodes' subnet), in
parallel with the cluster build, retrying
until capacity turns up. Its user data (compute/base.sh plus apps/<application>.sh)
waits for the cnq-path-extender:nfs-hosts tag, set once the portal is active, then mounts
the spoke. Setting up the environment is all it does: nothing is run on it.
"""

import os
import re
import shlex
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from common import EXTRA_TAGS, HUB_NAME, HUB_REGION, WorkflowError, state_outputs, number_input, options_input
from placement import cancel_reservations

HERE = os.path.dirname(os.path.abspath(__file__))
APPS_DIR = os.path.join(HERE, "apps")
COMPUTE_BASE_SCRIPT = os.path.join(HERE, "compute", "base.sh")


# Default AMIs (SSM public parameters), by whether the type has GPUs and its architecture.
# GPU types get the Deep Learning AMI, which adds NVIDIA drivers, Docker and the NVIDIA
# container toolkit to Amazon Linux 2023.
DEFAULT_AMI_PARAMS = {
    (False, "x86_64"): "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
    (False, "arm64"): "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64",
    (True, "x86_64"): "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id",
    (True, "arm64"): "/aws/service/deeplearning/ami/arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id",
}


COMPUTE_MOUNT_ROOT = "/mnt/qumulo"
COMPUTE_NFS_OPTIONS = "vers=3,tcp,hard,nconnect=16,rsize=1048576,wsize=1048576,noatime"
COMPUTE_KEYS = {
    "instance_types", "retry_minutes", "give_up_after_hours",
    "application", "application_options", "ami_id", "root_volume_gb",
}


# Tag value marking the compute instance.
COMPUTE_ROLE = "compute"


# Step Functions caps an execution at 25,000 history events; each hunt attempt uses ~10.
COMPUTE_MAX_ATTEMPTS = 1500


# Not enough capacity or quota right now: try the next type, then again after a wait.
COMPUTE_RETRYABLE = {
    "InsufficientInstanceCapacity", "InsufficientHostCapacity", "InsufficientCapacity",
    "InstanceLimitExceeded", "VcpuLimitExceeded", "Unsupported",
}


# The compute instance reads its mount settings from its own tags through instance metadata,
# which only allows tag keys made of these characters.
IMDS_TAG_KEY = re.compile(r"^[A-Za-z0-9+\-=.,_:@]+$")


def _apps():
    return sorted(f[:-3] for f in os.listdir(APPS_DIR) if f.endswith(".sh"))


def _app_requires(application):
    """What an application script says it needs, from "# requires: gpu" header lines."""
    needs = set()
    with open(os.path.join(APPS_DIR, f"{application}.sh")) as f:
        for line in f:
            if not line.startswith("#"):
                break
            m = re.match(r"#\s*requires:\s*(.+)", line)
            if m:
                needs |= {w.strip().lower() for w in m.group(1).split(",")}
    return needs


def compute_settings(raw, region):
    """Check the compute launch input and fill in defaults. {"requested": False} if absent."""
    if not raw:
        return {"requested": False}
    if not isinstance(raw, dict):
        raise WorkflowError('compute must be an object, e.g. {"instance_types": ["r7i.24xlarge"]}.')
    unknown = set(raw) - COMPUTE_KEYS
    if unknown:
        raise WorkflowError(f"Unknown compute settings: {', '.join(sorted(unknown))}. Allowed: {', '.join(sorted(COMPUTE_KEYS))}.")

    types = raw.get("instance_types")
    if isinstance(types, str):
        types = [types]
    if not types or not all(isinstance(t, str) and t for t in types):
        raise WorkflowError("compute.instance_types must list at least one instance type, in order of preference.")

    retry_minutes = number_input(raw.get("retry_minutes", 5), "compute.retry_minutes")
    hours = number_input(raw.get("give_up_after_hours", 24), "compute.give_up_after_hours", float)
    if not 2 <= retry_minutes <= 60:
        raise WorkflowError("compute.retry_minutes must be 2 to 60.")
    if not 0 < hours <= 168:
        raise WorkflowError("compute.give_up_after_hours must be more than 0 and at most 168.")
    if hours * 60 / retry_minutes > COMPUTE_MAX_ATTEMPTS:
        raise WorkflowError(
            f"compute: {hours} hours at one try every {retry_minutes} minutes is more than {COMPUTE_MAX_ATTEMPTS} "
            "attempts (a Step Functions history limit). Raise retry_minutes or lower give_up_after_hours."
        )

    application = (raw.get("application") or "").strip().lower()
    if application and application not in _apps():
        raise WorkflowError(f"Unknown compute.application '{application}'. Available: {', '.join(_apps()) or 'none'}.")
    options = options_input(raw.get("application_options"), "compute.application_options")

    root_volume_gb = number_input(raw.get("root_volume_gb", 200), "compute.root_volume_gb")
    if not 8 <= root_volume_gb <= 16384:
        raise WorkflowError("compute.root_volume_gb must be 8 to 16384.")

    # Optional; without it, each type gets its default AMI. An application can be set up
    # on either, but a custom AMI must have what the application needs.
    ami_id = (raw.get("ami_id") or "").strip()
    # An AMI ID belongs to one region, so a custom AMI needs a fixed region.
    if ami_id and not region:
        raise WorkflowError("compute.ami_id needs region: an AMI ID belongs to one region, so the tool can't search others.")

    bad_tags = [k for k in EXTRA_TAGS if not IMDS_TAG_KEY.fullmatch(k)]
    if bad_tags:
        raise WorkflowError(
            f"extra_tags keys {bad_tags} can't be used on a compute instance: with tags in instance "
            "metadata enabled, EC2 allows only letters, digits, and + - = . , _ : @ in tag keys."
        )

    # Every type must exist (in the spoke's region; with placement, none is chosen yet, so
    # the hub's). Its GPUs and architecture pick the default AMI.
    try:
        info = boto3.client("ec2", region_name=region or HUB_REGION).describe_instance_types(InstanceTypes=types)["InstanceTypes"]
    except ClientError as e:
        raise WorkflowError(f"compute.instance_types: {e.response['Error']['Message']}") from e
    kinds = {}
    for i in info:
        archs = i["ProcessorInfo"]["SupportedArchitectures"]
        kinds[i["InstanceType"]] = {
            "gpu": bool(i.get("GpuInfo", {}).get("Gpus")),
            "arch": "arm64" if "arm64" in archs else "x86_64",
        }
    if application and "gpu" in _app_requires(application):
        no_gpu = [t for t in types if not kinds[t]["gpu"]]
        if no_gpu:
            raise WorkflowError(f"compute.application {application} needs GPU instance types; these have none: {', '.join(no_gpu)}.")

    return {
        "requested": True,
        "instance_types": types,
        "kinds": kinds,
        "retry_minutes": retry_minutes,
        "give_up_after_hours": hours,
        "application": application,
        "application_options": options,
        "ami_id": ami_id,
        "root_volume_gb": root_volume_gb,
    }


def _compute_filters(region):
    return [
        {"Name": "tag:cnq-path-extender:hub", "Values": [HUB_NAME]},
        {"Name": "tag:cnq-path-extender:spoke-region", "Values": [region]},
        {"Name": "tag:cnq-path-extender:role", "Values": [COMPUTE_ROLE]},
    ]


def _compute_instances(ec2, region, states=("pending", "running", "stopping", "stopped")):
    resp = ec2.describe_instances(
        Filters=_compute_filters(region) + [{"Name": "instance-state-name", "Values": list(states)}]
    )
    return [i for r in resp["Reservations"] for i in r["Instances"]]


def _compute_user_data(launch):
    compute = launch["compute"]
    env = {
        "PA_HUB": HUB_NAME,
        "PA_REGION": launch["region"],
        "PA_SPOKE_PATH": launch["path"],
        "PA_MOUNT_ROOT": COMPUTE_MOUNT_ROOT,
        "PA_NFS_OPTIONS": COMPUTE_NFS_OPTIONS,
        "PA_APP": compute["application"],
    }
    env.update({f"APP_{k.upper()}": v for k, v in compute["application_options"].items()})

    parts = [
        "#!/bin/bash",
        f"# Generated by cnq-path-extender: compute instance for the {launch['region']} spoke of hub {HUB_NAME}.",
        "cat > /etc/cnq-path-extender.env <<'PA_ENV'",
        *(f"{k}={shlex.quote(str(v))}" for k, v in env.items()),
        "PA_ENV",
        "set -a; . /etc/cnq-path-extender.env; set +a",
    ]
    with open(COMPUTE_BASE_SCRIPT) as f:
        parts.append(f.read())
    if compute["application"]:
        with open(os.path.join(APPS_DIR, f"{compute['application']}.sh")) as f:
            parts.append(f"# ----- application: {compute['application']} -----\n" + f.read())
    # The mount usually comes later (it waits for the portal); see base.sh.
    parts.append(
        "touch /var/lib/cnq-path-extender/app-done\n"
        'if mountpoint -q "$PA_MOUNT_ROOT"; then\n'
        "  /usr/local/sbin/cnq-path-extender-finished\n"
        "else\n"
        '  pa_status "application setup done (${PA_APP:-none}); waiting for the portal before mounting"\n'
        "fi"
    )
    user_data = "\n".join(parts) + "\n"
    if len(user_data.encode()) > 16384:
        raise WorkflowError(f"Compute user data is {len(user_data.encode())} bytes; EC2 allows 16384.")
    return user_data


def _compute_image(region, compute, itype):
    """The custom AMI if given; otherwise Amazon Linux 2023 for the type's architecture,
    as the Deep Learning AMI (NVIDIA drivers, Docker) when the type has GPUs."""
    if compute["ami_id"]:
        return compute["ami_id"]
    kind = compute["kinds"][itype]
    param = DEFAULT_AMI_PARAMS[(kind["gpu"], kind["arch"])]
    try:
        return boto3.client("ssm", region_name=region).get_parameter(Name=param)["Parameter"]["Value"]
    except ClientError as e:
        raise WorkflowError(
            f"Couldn't look up the default AMI for {itype} in {region} ({param}): "
            f"{e.response['Error']['Message']}. Set compute.ami_id to an AMI in {region}."
        ) from e


def launch_compute(event):
    """One attempt to launch the compute instance. Never raises for no-capacity-yet.

    Returns launched (an instance exists, possibly from an earlier attempt or launch),
    gave_up (past the deadline), or neither (wait wait_seconds and call again).

    A capacity reservation found by the hunt is released once the instance is in it, and
    also when the launch fails or gives up: the deploy carries on without the instance,
    so nothing else would release it before it expires (and it's billed until then).
    """
    launch = event["launch"]
    reserved = (launch.get("capacity") or {}).get("reservation_id")
    try:
        result = _launch_compute(event)
    except Exception:
        if reserved:
            _release_quietly(launch["region"])
        raise
    if reserved and result["gave_up"]:
        _release_quietly(launch["region"])
    return result


def _release_quietly(region):
    """Cancel this hub's reservations in the region; the end date is the backstop."""
    try:
        cancel_reservations(region)
    except (BotoCoreError, ClientError):
        pass


def _launch_compute(event):
    launch, hunt = event["launch"], event.get("hunt") or {}
    compute, region = launch["compute"], launch["region"]
    # Local mode (deploy-local) sets site = "local" and its own state prefix; a spoke's
    # site is its region.
    site = launch.get("site") or region
    state_prefix = launch.get("state_prefix") or f"{HUB_NAME}/spokes/{region}"
    attempt = int(hunt.get("attempt", 0)) + 1
    deadline = int(hunt.get("deadline") or time.time() + compute["give_up_after_hours"] * 3600)
    result = {
        "requested": True, "launched": False, "gave_up": False,
        "attempt": attempt, "deadline": deadline, "wait_seconds": compute["retry_minutes"] * 60,
        "instance_id": None, "instance_type": None, "private_ip": None,
        "availability_zone": launch["availability_zone"], "application": compute["application"],
        "last_errors": [],
    }
    ec2 = boto3.client("ec2", region_name=region)
    # Capacity the hunt reserved: launch into it, then release it (a running instance
    # keeps running when its reservation is cancelled).
    capacity = launch.get("capacity") or {}

    def found(inst):
        result.update(
            launched=True, instance_id=inst["InstanceId"], instance_type=inst["InstanceType"],
            private_ip=inst.get("PrivateIpAddress"),
        )
        if capacity.get("reservation_id"):
            cancel_reservations(region)
        return result

    existing = _compute_instances(ec2, site)
    if existing:
        return found(existing[0])
    if time.time() > deadline:
        result["gave_up"] = True
        return result

    net = state_outputs(f"{state_prefix}/network.tfstate")
    if not net.get("client_security_group_id"):
        raise WorkflowError(f"The {site} network has no client resources; re-run the deploy to update it.")
    tags = [
        {"Key": k, "Value": v}
        for k, v in {
            **EXTRA_TAGS,
            "Name": f"{HUB_NAME}-{site}-compute",
            "cnq-path-extender:hub": HUB_NAME,
            "cnq-path-extender:spoke-region": site,
            "cnq-path-extender:role": COMPUTE_ROLE,
        }.items()
    ]

    reservation = {}
    if capacity.get("reservation_id"):
        reservation = {"CapacityReservationSpecification": {
            "CapacityReservationTarget": {"CapacityReservationId": capacity["reservation_id"]}
        }}
    for itype in [capacity["instance_type"]] if capacity.get("instance_type") else compute["instance_types"]:
        # The default AMI depends on the type (GPUs, architecture).
        image = _compute_image(region, compute, itype)
        root_device = ec2.describe_images(ImageIds=[image])["Images"][0]["RootDeviceName"]
        try:
            resp = ec2.run_instances(
                **reservation,
                ImageId=image,
                InstanceType=itype,
                MinCount=1,
                MaxCount=1,
                SubnetId=net["private_subnet_id"],
                SecurityGroupIds=[net["client_security_group_id"]],
                **({"KeyName": net["key_pair_name"]} if net.get("key_pair_name") else {}),
                IamInstanceProfile={"Name": net["client_instance_profile_name"]},
                UserData=_compute_user_data(launch),
                MetadataOptions={"HttpTokens": "required", "InstanceMetadataTags": "enabled"},
                BlockDeviceMappings=[{
                    "DeviceName": root_device,
                    "Ebs": {"VolumeSize": compute["root_volume_gb"], "VolumeType": "gp3", "DeleteOnTermination": True},
                }],
                TagSpecifications=[
                    {"ResourceType": "instance", "Tags": tags},
                    {"ResourceType": "volume", "Tags": tags},
                ],
                # A Lambda retry of this same attempt returns the same instance, not a second one.
                ClientToken=f"{deadline}-{attempt}-{itype}"[:64],
            )
        except ClientError as e:
            code = e.response["Error"]["Code"]
            # A new instance profile takes a few seconds to become usable by EC2.
            new_profile = code == "InvalidParameterValue" and "instance profile" in e.response["Error"]["Message"].lower()
            if code in COMPUTE_RETRYABLE or new_profile:
                result["last_errors"].append(f"{itype}: {code}")
                continue
            raise WorkflowError(f"RunInstances {itype} failed: {code}: {e.response['Error']['Message']}") from e
        return found(resp["Instances"][0])
    return result


def prepare_compute(event):
    """Tell the compute instance where to mount: it polls these tags through instance metadata."""
    region, compute = event["region"], event["compute"]
    boto3.client("ec2", region_name=region).create_tags(
        Resources=[compute["instance_id"]],
        Tags=[
            {"Key": "cnq-path-extender:nfs-hosts", "Value": " ".join(event["spoke"]["primary_ips"])},
            {"Key": "cnq-path-extender:nfs-path", "Value": event["path"]},
        ],
    )
    return {"mount": f"{COMPUTE_MOUNT_ROOT}{event['path']}"}


def terminate_compute(event):
    """destroy-spoke: remove the compute instance first; its network interface would block
    deleting the spoke's subnet and security group."""
    region = event["region"]
    site = event.get("site") or region  # "local" from destroy-local
    ec2 = boto3.client("ec2", region_name=region)
    ids = [i["InstanceId"] for i in _compute_instances(ec2, site, ("pending", "running", "stopping", "stopped", "shutting-down"))]
    if ids:
        ec2.terminate_instances(InstanceIds=ids)
        ec2.get_waiter("instance_terminated").wait(InstanceIds=ids, WaiterConfig={"Delay": 15, "MaxAttempts": 50})
    # Local mode reserves no capacity.
    cancelled = [] if event.get("site") else cancel_reservations(region)
    return {"terminated": ids, "reservations_cancelled": cancelled}
