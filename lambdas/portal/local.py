"""Local mode (docs/local-mode.md): run the modules in the hub's own VPC, mounting the
hub directly, with no spoke. The same-region baseline for work run on a spoke.

deploy-local calls validate_local, then reuses the compute actions (with site "local"
and the local state prefix) and the PCS stack (with the hub's network passed in).
"""

from collections import Counter

import boto3

from common import HUB_NAME, HUB_REGION, HUB_VPC_ID, WorkflowError, hub, hub_ips, path_input
from compute import compute_settings
from core import drop_placeholders
from pcs import pcs_settings

SITE = "local"
STATE_PREFIX = f"{HUB_NAME}/local"


def validate_local(event):
    """deploy-local's first step: check the input and find the hub nodes' subnet and IPs."""
    inp = drop_placeholders(event["input"])
    if not inp.get("path") or str(inp["path"]).startswith("<"):
        raise WorkflowError("Missing required input: path (a directory on the hub).")
    path = path_input(inp["path"])
    for key in ("region", "placement", "vpc_cidr"):
        if key in inp:
            raise WorkflowError(f"{key} doesn't apply to deploy-local: it always runs in the hub's VPC.")
    unknown = set(event["input"]) - {"path", "compute", "pcs"}
    if unknown:
        raise WorkflowError(f"Unknown inputs: {', '.join(sorted(unknown))}. deploy-local takes path, compute and pcs.")

    compute = compute_settings(inp.get("compute"), HUB_REGION)
    pcs = pcs_settings({} if event["input"].get("pcs") == {} else inp.get("pcs"), HUB_REGION)
    if not compute["requested"] and not pcs["requested"]:
        raise WorkflowError("Nothing to deploy: give compute, pcs, or both.")

    h = hub()
    if not h.exists(path):
        raise WorkflowError(f"Path {path} does not exist on the hub.")
    if h.attributes(path).get("type") != "FS_FILE_TYPE_DIRECTORY":
        raise WorkflowError(f"Path {path} on the hub is not a directory.")

    # Next to the hub's nodes: their subnet and zone (the most common, if they differ).
    ec2 = boto3.client("ec2", region_name=HUB_REGION)
    nodes = [
        i
        for r in ec2.describe_instances(Filters=[
            {"Name": "tag:Qumulo-Cluster", "Values": [HUB_NAME]},
            {"Name": "instance-state-name", "Values": ["running"]},
            {"Name": "vpc-id", "Values": [HUB_VPC_ID]},
        ])["Reservations"]
        for i in r["Instances"]
    ]
    if not nodes:
        raise WorkflowError(f"No running hub nodes found (tag Qumulo-Cluster = {HUB_NAME}).")
    subnet_id = Counter(i["SubnetId"] for i in nodes).most_common(1)[0][0]
    az = next(i["Placement"]["AvailabilityZone"] for i in nodes if i["SubnetId"] == subnet_id)

    # The instance types must be offered in that zone, or launches would retry forever.
    wanted = set(compute.get("instance_types", []))
    if pcs["requested"]:
        wanted |= {pcs["compute_instance_type"], pcs["login_instance_type"]}
    offered = {
        o["InstanceType"]
        for o in ec2.describe_instance_type_offerings(
            LocationType="availability-zone",
            Filters=[{"Name": "location", "Values": [az]}, {"Name": "instance-type", "Values": sorted(wanted)}],
        )["InstanceTypeOfferings"]
    }
    if compute["requested"] and not offered & set(compute["instance_types"]):
        raise WorkflowError(f"None of compute.instance_types is offered in {az}, the hub's zone.")
    if pcs["requested"]:
        missing = {pcs["compute_instance_type"], pcs["login_instance_type"]} - offered
        if missing:
            raise WorkflowError(f"pcs: {', '.join(sorted(missing))} isn't offered in {az}, the hub's zone.")

    return {
        "region": HUB_REGION,
        "site": SITE,
        "state_prefix": STATE_PREFIX,
        "path": path,
        "availability_zone": az,
        "network": {"vpc_id": HUB_VPC_ID, "subnet_id": subnet_id, "nfs_hosts": hub_ips()},
        "compute": compute,
        "pcs": pcs,
        "capacity": None,
    }
