"""The optional PCS cluster (the "pcs" launch input): AWS Parallel Computing Service
(managed Slurm) in the spoke's private subnet, its nodes mounting the spoke, optionally
with a pipeline set up on the login node.

Built by Terraform (spoke/pcs/) after the portal is up; this module only checks the input.
"""

import boto3
from botocore.exceptions import ClientError

from common import HUB_REGION, WorkflowError, number_input, options_input

# One script per pipeline in spoke/pcs/pipelines/. The Lambda doesn't ship spoke/, so the
# names are listed here too; spoke/pcs/variables.tf checks the same list.
PCS_PIPELINES = ("sarek", "xoos")

PCS_KEYS = {
    "pipeline", "pipeline_options", "compute_instance_type", "max_nodes",
    "login_instance_type", "root_volume_gb", "idle_minutes",
}
PCS_DEFAULTS = {
    "compute_instance_type": "c6i.4xlarge",
    "login_instance_type": "c6i.xlarge",
    "max_nodes": 4,
    "root_volume_gb": 100,
    # Should exceed a pipeline's longest single task, or the other nodes stop and must
    # boot again mid-run.
    "idle_minutes": 20,
}


def pcs_settings(raw, region):
    """Check the pcs launch input and fill in defaults. {"requested": False} if absent."""
    if raw is None:
        return {"requested": False}
    if not isinstance(raw, dict):
        raise WorkflowError('pcs must be an object, e.g. {"pipeline": "xoos"}, or {} for the cluster alone.')
    unknown = set(raw) - PCS_KEYS
    if unknown:
        raise WorkflowError(f"Unknown pcs settings: {', '.join(sorted(unknown))}. Allowed: {', '.join(sorted(PCS_KEYS))}.")
    if not region:
        raise WorkflowError("pcs needs region (not placement): PCS isn't offered in every region.")

    s = {**PCS_DEFAULTS, **{k: v for k, v in raw.items() if v not in (None, "")}}
    pipeline = str(s.get("pipeline", "")).strip().lower()
    if pipeline and pipeline not in PCS_PIPELINES:
        raise WorkflowError(f"Unknown pcs.pipeline '{pipeline}'. Available: {', '.join(PCS_PIPELINES)}.")
    options = options_input(s.get("pipeline_options"), "pcs.pipeline_options")
    max_nodes = number_input(s["max_nodes"], "pcs.max_nodes")
    if not 1 <= max_nodes <= 64:
        raise WorkflowError("pcs.max_nodes must be 1 to 64.")
    root_volume_gb = number_input(s["root_volume_gb"], "pcs.root_volume_gb")
    if not 30 <= root_volume_gb <= 16384:
        raise WorkflowError("pcs.root_volume_gb must be 30 to 16384.")
    idle_minutes = number_input(s["idle_minutes"], "pcs.idle_minutes")
    if not 1 <= idle_minutes <= 1440:
        raise WorkflowError("pcs.idle_minutes must be 1 to 1440.")

    # PCS must be offered in the region (AWS's public list of regional services).
    ssm = boto3.client("ssm", region_name=HUB_REGION)
    try:
        ssm.get_parameter(Name=f"/aws/service/global-infrastructure/regions/{region}/services/pcs")
    except ssm.exceptions.ParameterNotFound:
        raise WorkflowError(f"AWS PCS isn't offered in {region}.") from None

    # Both types must exist there, on x86_64: the node setup installs x86_64 packages.
    types = sorted({s["compute_instance_type"], s["login_instance_type"]})
    ec2 = boto3.client("ec2", region_name=region)
    try:
        info = ec2.describe_instance_types(InstanceTypes=types)["InstanceTypes"]
    except ClientError as e:
        raise WorkflowError(f"pcs instance types: {e.response['Error']['Message']}") from e
    for i in info:
        if "x86_64" not in i["ProcessorInfo"]["SupportedArchitectures"]:
            raise WorkflowError(f"pcs: {i['InstanceType']} isn't x86_64; the node setup needs x86_64.")
    offered = {
        o["InstanceType"]
        for o in ec2.describe_instance_type_offerings(
            LocationType="region", Filters=[{"Name": "instance-type", "Values": types}]
        )["InstanceTypeOfferings"]
    }
    missing = [t for t in types if t not in offered]
    if missing:
        raise WorkflowError(f"pcs: {region} doesn't offer {', '.join(missing)}.")

    return {
        "requested": True,
        "pipeline": pipeline,
        "pipeline_options": options,
        "compute_instance_type": s["compute_instance_type"],
        "login_instance_type": s["login_instance_type"],
        "max_nodes": max_nodes,
        "root_volume_gb": root_volume_gb,
        "idle_minutes": idle_minutes,
    }
