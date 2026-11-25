"""The core spoke lifecycle: check a launch, read a spoke's state, its health, the
destroy build's cleanup report, and forget a destroyed spoke."""

import ipaddress
import json

import boto3

from common import (
    DEFAULT_INSTANCE_TYPE, DEFAULT_NODE_COUNT, HUB_NAME, HUB_REGION, HUB_VPC_CIDR, HUB_VPC_ID,
    STATE_BUCKET, SUPPORTED_FAMILIES, Qumulo, WorkflowError, flag, state_outputs, hub, hub_ips,
    hub_uuid, number_input, path_input,
)
from compute import compute_settings
from pcs import pcs_settings
from placement import (
    capacity_candidates, check_az, check_cluster_fits, first_region_that_fits, latency_from_hub,
)
from portal import hub_portal_problems


def probe_hub(_event):
    """Used once by bootstrap: confirm the hub answers, record its identity and version."""
    h = hub()
    return {"cluster_uuid": h.cluster_id(), "version": h.version()}


def drop_placeholders(value):
    """Remove fields still holding an "<OPTIONAL: ...>" placeholder from the launch_example
    output, and any object or list left empty, so untouched optional fields mean default."""
    if isinstance(value, dict):
        out = {k: drop_placeholders(v) for k, v in value.items()}
        return {k: v for k, v in out.items() if v not in (None, {}, [])}
    if isinstance(value, list):
        return [v for v in (drop_placeholders(v) for v in value) if v not in (None, {}, [])]
    if isinstance(value, str) and value.startswith("<OPTIONAL"):
        return None
    return value


LAUNCH_KEYS = {
    "region", "placement", "path", "vpc_cidr", "instance_type", "node_count",
    "availability_zone", "client_resources", "compute", "pcs",
}


def validate(event):
    """deploy-spoke's first step: check the launch input and settle where the spoke goes."""
    unknown = set(event["input"]) - LAUNCH_KEYS
    if unknown:
        raise WorkflowError(f"Unknown inputs: {', '.join(sorted(unknown))}. Allowed: {', '.join(sorted(LAUNCH_KEYS))}.")
    inp = drop_placeholders(event["input"])
    for key in ("region", "path", "vpc_cidr"):
        if str(inp.get(key, "")).startswith("<"):
            raise WorkflowError(f"Fill in {key}: it still holds the placeholder {inp[key]}.")
    for key in ("path", "vpc_cidr"):
        if not inp.get(key):
            raise WorkflowError(f"Missing required input: {key}")

    region = inp.get("region") or ""
    path = path_input(inp["path"])
    instance_type = inp.get("instance_type") or DEFAULT_INSTANCE_TYPE
    node_count = number_input(inp.get("node_count") or DEFAULT_NODE_COUNT, "node_count")
    requested_az = inp.get("availability_zone") or ""

    # Where the spoke goes: a region, or "placement" to let the tool choose one. An empty
    # placement ({}) means "search every region", so its presence is read before
    # placeholders and empty objects are dropped.
    placed = "placement" in event["input"]
    placement = inp.get("placement") or {}
    if not isinstance(placement, dict):
        raise WorkflowError('placement must be an object, e.g. {"regions": ["ap-northeast-2"]}, or {} for any region.')
    if set(placement) - {"regions"}:
        raise WorkflowError(f"Unknown placement settings: {', '.join(sorted(set(placement) - {'regions'}))}. Allowed: regions.")
    regions = placement.get("regions") or []
    if isinstance(regions, str):
        regions = [regions]
    if region and placed:
        raise WorkflowError("Give region or placement, not both.")
    if not region and not placed:
        raise WorkflowError('region is required, or placement to let the tool choose one: "placement": {} for any region.')
    if requested_az and not region:
        raise WorkflowError("availability_zone needs region (zone names belong to a region).")

    # Sizing
    if instance_type.split(".")[0] not in SUPPORTED_FAMILIES:
        raise WorkflowError(
            f"instance_type {instance_type} is not in a supported family: {', '.join(SUPPORTED_FAMILIES)}"
        )
    if not (node_count == 1 or 3 <= node_count <= 24):
        raise WorkflowError(f"node_count must be 1 or 3-24, got {node_count}.")

    compute = compute_settings(inp.get("compute"), region)
    # "pcs": {} means the cluster alone, so it's read before empty objects are dropped; a
    # pcs block holding only placeholders (launch_example, untouched) means no PCS.
    pcs = pcs_settings({} if event["input"].get("pcs") == {} else inp.get("pcs"), region)

    # Regions
    ec2_hub = boto3.client("ec2", region_name=HUB_REGION)
    enabled = {r["RegionName"] for r in ec2_hub.describe_regions()["Regions"]}
    for r in [region] if region else regions:
        if r not in enabled:
            raise WorkflowError(f"Region {r} is not enabled for this account.")
        if r == HUB_REGION:
            raise WorkflowError("The spoke must be in a different region from the hub.")

    # CIDR: valid, sized, and no overlap with the hub or any VPC peered with it
    try:
        cidr = ipaddress.ip_network(inp["vpc_cidr"], strict=True)
    except ValueError as e:
        raise WorkflowError(f"vpc_cidr is not a valid network: {e}") from e
    if not 16 <= cidr.prefixlen <= 24:
        raise WorkflowError("vpc_cidr must be between /16 and /24.")

    # This hub's existing spokes (by region), and every network peered with the hub.
    taken = {HUB_VPC_CIDR: f"hub VPC {HUB_VPC_ID}"}
    spokes = {}
    for pcx in _hub_peerings(ec2_hub):
        spoke_cidrs = []
        for side in ("RequesterVpcInfo", "AccepterVpcInfo"):
            info = pcx[side]
            if info["VpcId"] != HUB_VPC_ID:
                for block in info.get("CidrBlockSet", []) or [{"CidrBlock": info.get("CidrBlock")}]:
                    if block.get("CidrBlock"):
                        spoke_cidrs.append(block["CidrBlock"])
        tags = {t["Key"]: t["Value"] for t in pcx.get("Tags", [])}
        if tags.get("cnq-path-extender:hub") == HUB_NAME and tags.get("cnq-path-extender:spoke-region"):
            spokes[tags["cnq-path-extender:spoke-region"]] = spoke_cidrs
        for block in spoke_cidrs:
            taken[block] = f"a VPC peered with the hub ({pcx['VpcPeeringConnectionId']})"

    # An existing spoke means an earlier launch stopped partway (or this is a re-run).
    # Resume it when the inputs match: Terraform reports no changes for what exists,
    # create_portal reuses an existing portal, and accept/verify finish the job. Without a
    # region, the spoke with this CIDR is the one to resume, so a re-run never hunts again
    # and builds a second spoke elsewhere. Different inputs are refused.
    if not region:
        matches = [r for r, cidrs in spokes.items() if str(cidr) in cidrs]
        if matches:
            region = matches[0]
    previous_az, previous_launch = None, {}
    if region in spokes:
        if str(cidr) not in spokes[region]:
            raise WorkflowError(
                f"A spoke in {region} already exists with vpc_cidr {', '.join(spokes[region])}. "
                "Launch again with that CIDR to resume it, or run destroy-spoke for the region first."
            )
        for block in spokes[region]:
            taken.pop(block, None)
        prefix = f"{HUB_NAME}/spokes/{region}"
        network = state_outputs(f"{prefix}/network.tfstate")
        previous_az, previous_launch = network.get("availability_zone"), network.get("launch", {})
        if state_outputs(f"{prefix}/cluster.tfstate").get("primary_ips"):
            launched = previous_launch
            if (launched.get("instance_type"), launched.get("node_count")) != (instance_type, node_count):
                raise WorkflowError(
                    f"A spoke in {region} already exists with {launched.get('node_count')} x "
                    f"{launched.get('instance_type')}. Launch again with the same size to resume it, "
                    "or run destroy-spoke for the region first."
                )

    for other, owner in taken.items():
        if cidr.overlaps(ipaddress.ip_network(other)):
            raise WorkflowError(f"vpc_cidr {cidr} overlaps {other} used by {owner}.")

    # Hub identity, path, version
    h = hub()
    cluster_uuid = h.cluster_id()
    if hub_uuid() and cluster_uuid != hub_uuid():
        raise WorkflowError(
            f"Hub identity changed: expected cluster {hub_uuid()}, found {cluster_uuid}. "
            "Re-run bootstrap if the hub was rebuilt."
        )
    if not h.exists(path):
        raise WorkflowError(f"Path {path} does not exist on the hub.")
    if h.attributes(path).get("type") != "FS_FILE_TYPE_DIRECTORY":
        raise WorkflowError(f"Path {path} on the hub is not a directory.")
    hub_portal_warnings = hub_portal_problems(h)

    # Where the spoke goes. An existing spoke keeps its region and zone (moving it would
    # rebuild the network). For a new spoke:
    # - with compute: the capacity hunt reserves the compute instance's capacity first, in
    #   region, or across placement's search; here we only list the zones it may try;
    # - with placement and no compute: the first region in the search the cluster fits;
    # - otherwise: region as given, with a requested zone checked, or "" to let the network
    #   stack pick.
    hunt, candidates, skipped, search_order = False, [], {}, []
    if previous_az:
        if requested_az and requested_az != previous_az:
            raise WorkflowError(
                f"The spoke in {region} is in {previous_az}. Launch again without availability_zone "
                "(or with that zone) to resume it, or run destroy-spoke for the region first."
            )
        az = previous_az
    elif region not in spokes and (compute["requested"] or not region):
        if region:
            search = [region]
        else:
            # One spoke per region per hub: regions that already have one are left out.
            skipped = {r: "already has a spoke of this hub" for r in regions if r in spokes}
            if regions:
                search = [r for r in regions if r not in spokes]
            else:
                # Nearest first, measured from the hub, so a region close to the data wins
                # when several could take the spoke.
                latency = latency_from_hub(enabled - {HUB_REGION} - set(spokes))
                search = sorted(latency, key=lambda r: (latency[r] is None, latency[r] or 0, r))
                search_order = [f"{r} ({latency[r]} ms)" if latency[r] is not None else f"{r} (no answer)" for r in search]
        if compute["requested"]:
            candidates, more = capacity_candidates(search, instance_type, node_count, compute, requested_az)
            skipped.update(more)
            if not candidates:
                reasons = "; ".join(f"{r}: {why}" for r, why in skipped.items())
                raise WorkflowError(f"No region can take this spoke and its compute instance. {reasons}")
            hunt, region, az = True, "", ""
        else:
            region, more = first_region_that_fits(search, instance_type, node_count)
            skipped.update(more)
            if not region:
                reasons = "; ".join(f"{r}: {why}" for r, why in skipped.items())
                raise WorkflowError(f"No region can take this spoke. {reasons}")
            az = ""
    elif requested_az:
        az = check_az(region, instance_type, requested_az)
    else:
        az = ""
    # Placement and the capacity hunt check their own candidates; otherwise check a new
    # spoke here, so a spoke that can't be built fails in seconds rather than 15 minutes
    # into the build.
    if region and region not in spokes and not placed:
        check_cluster_fits(region, instance_type, node_count)

    # Once created, client resources stay: instances may be using them, and removing
    # their security group would fail the network apply.
    client_resources = bool(
        flag(inp.get("client_resources"), "client_resources")
        or compute["requested"]
        or previous_launch.get("client_resources")
    )

    return {
        "region": region,
        "path": path,
        "vpc_cidr": str(cidr),
        "instance_type": instance_type,
        "node_count": node_count,
        "cluster_version": h.version(),
        "availability_zone": az,
        "client_resources": client_resources,
        "compute": compute,
        "pcs": pcs,
        "hunt": hunt,
        "candidates": candidates,
        "skipped_regions": skipped,
        "search_order": search_order,
        "capacity": None,
        "hub_portal_warnings": hub_portal_warnings,
    }


def _hub_peerings(ec2):
    out = []
    for side in ("requester-vpc-info.vpc-id", "accepter-vpc-info.vpc-id"):
        resp = ec2.describe_vpc_peering_connections(
            Filters=[
                {"Name": side, "Values": [HUB_VPC_ID]},
                {"Name": "status-code", "Values": ["pending-acceptance", "provisioning", "active"]},
            ]
        )
        out.extend(resp["VpcPeeringConnections"])
    return out


def read_spoke(event):
    """Read the spoke's outputs from its network and cluster state files in S3.

    The network stack must exist. The cluster stack may be missing or empty (its apply
    failed, or it was already destroyed): has_cluster is then false and primary_ips empty,
    so destroy-spoke can skip portal removal and still tear down the network.
    """
    prefix = f"{HUB_NAME}/spokes/{event['region']}"
    network = state_outputs(f"{prefix}/network.tfstate")
    if "launch" not in network:
        raise WorkflowError(
            f"No spoke found for region {event['region']} (s3://{STATE_BUCKET}/{prefix}/network.tfstate "
            "is missing or empty)."
        )
    cluster = state_outputs(f"{prefix}/cluster.tfstate")
    has_cluster = bool(cluster.get("primary_ips"))

    # destroy-spoke asks for this before touching anything: a stopped cluster would have
    # its portal half-removed and then be dropped from state by the Qumulo provider.
    if event.get("require_running") and has_cluster:
        stopped = _stopped_instances(event["region"], cluster.get("deployment_unique_name", ""))
        if stopped:
            raise WorkflowError(
                f"The spoke in {event['region']} has stopped instances ({', '.join(stopped)}). "
                "The Qumulo provider treats a stopped cluster as gone, so Terraform would lose "
                "track of it instead of destroying it. Start the instances, wait until they're "
                "running, then run destroy-spoke again."
            )

    return {
        "has_cluster": has_cluster,
        "primary_ips": cluster.get("primary_ips", []),
        "api_endpoint": cluster.get("api_endpoint", ""),
        "cluster_uuid": cluster.get("cluster_uuid", ""),
        "deployment_unique_name": cluster.get("deployment_unique_name", ""),
        "admin_secret_arn": network["admin_secret_arn"],
        "launch": network["launch"],
    }


def _stopped_instances(region, deployment):
    if not deployment:
        return []
    resp = boto3.client("ec2", region_name=region).describe_instances(
        Filters=[
            {"Name": "tag:Qumulo-Cluster", "Values": [deployment]},
            {"Name": "instance-state-name", "Values": ["stopping", "stopped"]},
        ]
    )
    return [i["InstanceId"] for r in resp["Reservations"] for i in r["Instances"]]


def check_health(event):
    """All spoke nodes ACTIVE in quorum. Never raises for not-ready-yet."""
    s, attempt = event["spoke"], int(event.get("attempt", 0)) + 1
    if not s.get("primary_ips"):
        return {"healthy": False, "reason": "spoke cluster has no node IPs yet", "attempt": attempt}
    try:
        for ip in s["primary_ips"]:
            state = Qumulo([ip], s["admin_secret_arn"]).request("GET", "/v1/node/state")["state"]
            if state != "ACTIVE":
                return {"healthy": False, "reason": f"node {ip} is {state}", "attempt": attempt}
        return {"healthy": True, "reason": "all nodes ACTIVE", "attempt": attempt}
    except Exception as e:  # booting nodes refuse connections or logins
        return {"healthy": False, "reason": str(e)[:500], "attempt": attempt}


def cleanup_report(event):
    """destroy-spoke: what the destroy build's sweep and final check found
    (spoke/cleanup.py), from the report it leaves next to the spoke's state."""
    # state_prefix: set by destroy-local (local mode), whose state lives elsewhere.
    prefix = event.get("state_prefix") or f"{HUB_NAME}/spokes/{event['region']}"
    key = f"{prefix}/cleanup-report.json"
    s3 = boto3.client("s3")
    try:
        report = json.loads(s3.get_object(Bucket=STATE_BUCKET, Key=key)["Body"].read())
    except s3.exceptions.NoSuchKey as e:
        raise WorkflowError(f"The destroy build left no cleanup report (s3://{STATE_BUCKET}/{key}).") from e
    if event.get("build_id") and report.get("run_id") != event["build_id"]:
        raise WorkflowError(
            f"The cleanup report is from another build ({report.get('run_id')}), so this destroy "
            "build didn't finish its check. See the build log."
        )
    leftovers = [
        f"{x['kind']} {x['id']} ({x['where']})"
        + (f": {x['detail']}" if x["detail"] else "")
        + ("" if x["auto"] else " [needs a person]")
        for x in report["leftovers"]
    ]
    return {
        "clean": bool(report["clean"]),
        "leftovers": leftovers,
        "check_errors": report["errors"],
        "removed_by_sweep": report["removed"],
    }


def forget_spoke(event):
    """destroy-spoke, once the cleanup check is clean: delete the spoke's files in the state
    bucket (its emptied state files, locks, cleanup report), so the region no longer reads
    as having a spoke. In a versioned bucket the old versions remain."""
    # state_prefix: set by destroy-local (local mode), whose state lives elsewhere.
    prefix = (event.get("state_prefix") or f"{HUB_NAME}/spokes/{event['region']}") + "/"
    s3 = boto3.client("s3")
    keys = [
        o["Key"]
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=STATE_BUCKET, Prefix=prefix)
        for o in page.get("Contents", [])
    ]
    for i in range(0, len(keys), 1000):
        resp = s3.delete_objects(
            Bucket=STATE_BUCKET,
            Delete={"Objects": [{"Key": k} for k in keys[i:i + 1000]], "Quiet": True},
        )
        if resp.get("Errors"):
            raise WorkflowError(f"Couldn't delete some of s3://{STATE_BUCKET}/{prefix}: {resp['Errors']}")
    return {"deleted": keys}


def list_spokes(event):
    """refresh-hub: the regions with a spoke of this hub (from their state files), or just
    the region given; and the hub's current node IPs, for the record."""
    region = (event.get("input") or {}).get("region")
    if region:
        regions = [region]
    else:
        prefix = f"{HUB_NAME}/spokes/"
        pages = boto3.client("s3").get_paginator("list_objects_v2").paginate(
            Bucket=STATE_BUCKET, Prefix=prefix, Delimiter="/"
        )
        regions = sorted(
            p["Prefix"][len(prefix):].strip("/") for page in pages for p in page.get("CommonPrefixes", [])
        )
    return {"regions": regions, "hub_ips": hub_ips()}
