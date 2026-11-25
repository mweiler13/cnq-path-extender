#!/usr/bin/env python3
"""Find, and optionally remove, everything a spoke of this hub can leave behind.

    cleanup.py check --hub H --hub-region R --region S [--vpc-cidr C] [--report FILE]
    cleanup.py sweep --hub H --hub-region R --region S [--vpc-cidr C] [--report FILE]

check is read-only: it lists what's left of the spoke and exits 1 if anything is. sweep
removes what it can, then checks. The destroy build runs sweep after terraform destroy,
so resources Terraform lost track of (a create that failed or was aborted partway, say)
go too. check can also be run by hand with read-only credentials.

Only resources tagged cnq-path-extender:hub = H and cnq-path-extender:spoke-region = S are
removed, plus the few things that can't carry tags and are named for this spoke: its
key pair, secrets, hub routes to its peering connections, and rules on the hub's CDF
security group tagged for it. Anything that matches by name but not by tag (perhaps
another hub's spoke) is reported for a person to decide, never removed.

Needs Python 3 and boto3.
"""

import argparse
import json
import sys
import time

import boto3
from botocore.exceptions import ClientError, EndpointConnectionError

LIVE_INSTANCE = ["pending", "running", "stopping", "stopped", "shutting-down"]
GONE_PEERING = {"deleted", "deleting", "rejected", "failed", "expired"}
# Resource types checked one by one below. The tagging API lists deleted resources for a
# while after they're gone, so it's only used for types not covered here.
COVERED = ("ec2", "secretsmanager", "kms", "s3", "logs", "iam", "pcs")


class Spoke:
    def __init__(self, hub, hub_region, region, vpc_cidr):
        self.hub, self.hub_region, self.region, self.vpc_cidr = hub, hub_region, region, vpc_cidr
        self.prefix = "spk" + region.replace("-", "")  # the cluster's deployment name
        self.ec2 = boto3.client("ec2", region_name=region)
        self.hub_ec2 = boto3.client("ec2", region_name=hub_region)
        self.iam = boto3.client("iam")
        self.tag_filters = [
            {"Name": "tag:cnq-path-extender:hub", "Values": [hub]},
            {"Name": "tag:cnq-path-extender:spoke-region", "Values": [region]},
        ]

    def ours(self, tags):
        t = {x["Key"]: x["Value"] for x in tags or []}
        return t.get("cnq-path-extender:hub") == self.hub and t.get("cnq-path-extender:spoke-region") == self.region

    def client(self, service, region=None):
        return boto3.client(service, region_name=region or self.region)


def item(kind, rid, where, detail="", auto=True):
    """auto: sweep can remove it. Otherwise a person has to look."""
    return {"kind": kind, "id": rid, "where": where, "detail": detail, "auto": auto}


# -----------------------------------------------------------------------------
# Checks: each returns a list of leftovers
# -----------------------------------------------------------------------------


def instances(s):
    resp = s.ec2.describe_instances(
        Filters=s.tag_filters + [{"Name": "instance-state-name", "Values": LIVE_INSTANCE}]
    )
    return [
        item("instance", i["InstanceId"], s.region, f"{i['InstanceType']} {i['State']['Name']}")
        for r in resp["Reservations"] for i in r["Instances"]
    ]


def capacity_reservations(s):
    resp = s.ec2.describe_capacity_reservations(
        Filters=s.tag_filters + [{"Name": "state", "Values": ["active", "pending"]}]
    )
    return [
        item("capacity reservation", r["CapacityReservationId"], s.region, f"{r['InstanceType']}, billed until cancelled")
        for r in resp["CapacityReservations"]
    ]


def vpcs(s):
    return [item("VPC", v["VpcId"], s.region, v["CidrBlock"]) for v in s.ec2.describe_vpcs(Filters=s.tag_filters)["Vpcs"]]


def security_groups(s):
    return [
        item("security group", g["GroupId"], s.region, f"{g['GroupName']} in {g['VpcId']}")
        for g in s.ec2.describe_security_groups(Filters=s.tag_filters)["SecurityGroups"]
    ]


def volumes(s):
    # A volume already "deleting" is on its way out (large volumes can take minutes).
    return [
        item("EBS volume", v["VolumeId"], s.region, v["State"])
        for v in s.ec2.describe_volumes(Filters=s.tag_filters)["Volumes"]
        if v["State"] not in ("deleting", "deleted")
    ]


def addresses(s):
    return [
        item("Elastic IP", a["AllocationId"], s.region, a.get("PublicIp", ""))
        for a in s.ec2.describe_addresses(Filters=s.tag_filters)["Addresses"]
    ]


def placement_groups(s):
    """The cluster's placement group. It's removable only once its instances are gone."""
    return [
        item("placement group", g["GroupName"], s.region, g["State"])
        for g in s.ec2.describe_placement_groups(Filters=s.tag_filters)["PlacementGroups"]
        if g["State"] != "deleted"
    ]


def launch_templates(s):
    """The PCS node groups' launch templates."""
    return [
        item("launch template", t["LaunchTemplateId"], s.region, t["LaunchTemplateName"])
        for t in s.ec2.describe_launch_templates(Filters=s.tag_filters)["LaunchTemplates"]
    ]


def _pcs_list(call, key, **kwargs):
    out, token = [], None
    while True:
        resp = call(**kwargs, **({"nextToken": token} if token else {}))
        out += resp.get(key, [])
        token = resp.get("nextToken")
        if not token:
            return out


def pcs_clusters(s):
    """The PCS cluster (removed with its queues and node groups, whose instances go too)."""
    pcs = s.client("pcs")
    try:
        clusters = _pcs_list(pcs.list_clusters, "clusters")
    except EndpointConnectionError:
        return []  # PCS isn't offered in this region
    out = []
    for c in clusters:
        if s.ours([{"Key": k, "Value": v} for k, v in pcs.list_tags_for_resource(resourceArn=c["arn"]).get("tags", {}).items()]):
            out.append(item("PCS cluster", c["id"], s.region, f"{c['name']} {c['status']}"))
    return out


def _delete_pcs_cluster(s, cluster_id, log):
    """Queues, then node groups (which terminate their instances), then the cluster."""
    pcs = s.client("pcs")
    for q in _pcs_list(pcs.list_queues, "queues", clusterIdentifier=cluster_id):
        _try(log, f"PCS queue {q['id']}", pcs.delete_queue, clusterIdentifier=cluster_id, queueIdentifier=q["id"])
    groups = _pcs_list(pcs.list_compute_node_groups, "computeNodeGroups", clusterIdentifier=cluster_id)
    for g in groups:
        if g["status"] != "DELETING":
            _try(log, f"PCS node group {g['id']}", pcs.delete_compute_node_group,
                 clusterIdentifier=cluster_id, computeNodeGroupIdentifier=g["id"])
    for _ in range(60):  # node groups and queues must be gone before the cluster can go
        if not (_pcs_list(pcs.list_compute_node_groups, "computeNodeGroups", clusterIdentifier=cluster_id)
                or _pcs_list(pcs.list_queues, "queues", clusterIdentifier=cluster_id)):
            break
        time.sleep(15)
    _try(log, f"PCS cluster {cluster_id}", pcs.delete_cluster, clusterIdentifier=cluster_id)


def key_pair(s):
    name = f"{s.hub}-{s.region}"
    pairs = s.ec2.describe_key_pairs(Filters=[{"Name": "key-name", "Values": [name]}])["KeyPairs"]
    return [item("key pair", p["KeyName"], s.region) for p in pairs]


def secrets(s):
    sm = s.client("secretsmanager")
    out = []
    for page in sm.get_paginator("list_secrets").paginate(
        IncludePlannedDeletion=True, Filters=[{"Key": "name", "Values": [f"cnq-path-extender/{s.hub}/{s.region}/"]}]
    ):
        out += [item("secret", x["Name"], s.region) for x in page["SecretList"]]
    return out


def log_groups(s):
    logs = s.client("logs")
    out = []
    for page in logs.get_paginator("describe_log_groups").paginate(logGroupNamePrefix=f"/qumulo/{s.prefix}-"):
        for g in page["logGroups"]:
            tags = logs.list_tags_log_group(logGroupName=g["logGroupName"]).get("tags", {})
            hub = tags.get("cnq-path-extender:hub")
            if hub and hub != s.hub:
                continue  # another hub's spoke in this region
            out.append(item("log group", g["logGroupName"], s.region, auto=hub == s.hub,
                            detail="" if hub else "untagged: may belong to another hub's spoke; check before deleting"))
    return out


def _tagged_arns(s, type_filters=None):
    tagging = s.client("resourcegroupstaggingapi")
    kwargs = {"TagFilters": [
        {"Key": "cnq-path-extender:hub", "Values": [s.hub]},
        {"Key": "cnq-path-extender:spoke-region", "Values": [s.region]},
    ]}
    if type_filters:
        kwargs["ResourceTypeFilters"] = type_filters
    arns = []
    for page in tagging.get_paginator("get_resources").paginate(**kwargs):
        arns += [r["ResourceARN"] for r in page["ResourceTagMappingList"]]
    return arns


def kms_keys(s):
    kms = s.client("kms")
    out = []
    for arn in _tagged_arns(s, ["kms:key"]):
        try:
            state = kms.describe_key(KeyId=arn)["KeyMetadata"]["KeyState"]
        except ClientError:
            continue  # gone
        if state not in ("PendingDeletion", "PendingReplicaDeletion"):
            out.append(item("KMS key", arn, s.region, state))
    return out


def buckets(s):
    s3 = s.client("s3")
    out = []
    for arn in _tagged_arns(s, ["s3:bucket"]):
        name = arn.split(":::")[-1]
        try:
            s3.head_bucket(Bucket=name)
        except ClientError:
            continue  # gone
        out.append(item("S3 bucket", name, s.region, "its contents are deleted with it"))
    return out


def other_tagged(s):
    """Anything else tagged for this spoke, of a type not checked above."""
    ssm = s.client("ssm")
    out = []
    for arn in _tagged_arns(s):
        service = arn.split(":")[2]
        if service in COVERED:
            continue
        if service == "ssm" and ":parameter/" in arn:
            try:
                ssm.get_parameter(Name="/" + arn.split(":parameter/", 1)[1])
            except ssm.exceptions.ParameterNotFound:
                continue  # gone; the tagging API hasn't caught up
        out.append(item("tagged resource", arn, s.region, "not a type this check knows; check before deleting", auto=False))
    return out


def iam_roles(s):
    out = []
    fixed = {f"{s.hub}-{s.region}-{x}" for x in ("compute", "pcs")}
    names = set(fixed)
    for page in s.iam.get_paginator("list_roles").paginate():
        names |= {r["RoleName"] for r in page["Roles"] if r["RoleName"].startswith(f"{s.prefix}-")}
    for name in sorted(names):
        try:
            tags = s.iam.list_role_tags(RoleName=name)["Tags"]
        except s.iam.exceptions.NoSuchEntityException:
            continue
        hub = {t["Key"]: t["Value"] for t in tags}.get("cnq-path-extender:hub")
        if hub and hub != s.hub:
            continue
        mine = s.ours(tags) or name in fixed
        out.append(item("IAM role", name, "global", auto=mine,
                        detail="" if mine else "untagged: may belong to another hub's spoke; check before deleting"))
    return out


def instance_profiles(s):
    """Instance profiles carry no tags here, so they're judged by their role's tags."""
    out = []
    for page in s.iam.get_paginator("list_instance_profiles").paginate():
        for p in page["InstanceProfiles"]:
            name = p["InstanceProfileName"]
            if name in {f"{s.hub}-{s.region}-{x}" for x in ("compute", "pcs")}:
                out.append(item("IAM instance profile", name, "global"))
            elif name.startswith(f"{s.prefix}-"):
                hubs = {
                    {t["Key"]: t["Value"] for t in _role_tags(s, r["RoleName"])}.get("cnq-path-extender:hub")
                    for r in p["Roles"]
                }
                if hubs - {s.hub, None}:
                    continue  # another hub's spoke
                mine = hubs == {s.hub}
                out.append(item("IAM instance profile", name, "global", auto=mine,
                                detail="" if mine else "no tagged role: may belong to another hub's spoke; check before deleting"))
    return out


def _role_tags(s, name):
    try:
        return s.iam.list_role_tags(RoleName=name)["Tags"]
    except s.iam.exceptions.NoSuchEntityException:
        return []


def peerings(s):
    resp = s.hub_ec2.describe_vpc_peering_connections(Filters=s.tag_filters)
    return [
        item("VPC peering", p["VpcPeeringConnectionId"], s.hub_region, p["Status"]["Code"])
        for p in resp["VpcPeeringConnections"] if p["Status"]["Code"] not in GONE_PEERING
    ]


def _cdf_group(s):
    groups = s.hub_ec2.describe_security_groups(
        Filters=[{"Name": "group-name", "Values": [f"cdf-{s.hub}"]}]
    )["SecurityGroups"]
    return groups[0] if groups else None


def cdf_rules(s):
    sg = _cdf_group(s)
    if not sg:
        return []
    rules = s.hub_ec2.describe_security_group_rules(
        Filters=[{"Name": "group-id", "Values": [sg["GroupId"]]},
                 {"Name": "tag:cnq-path-extender:spoke-region", "Values": [s.region]}]
    )["SecurityGroupRules"]
    return [item("CDF security group rule", r["SecurityGroupRuleId"], s.hub_region,
                 f"{sg['GroupId']} from {r.get('CidrIpv4', '')}") for r in rules]


def hub_routes(s):
    """Routes in the hub VPC to this spoke: via its peering connections (any state), or to
    its CIDR through a peering connection that no longer exists (a blackhole)."""
    peerings_ = s.hub_ec2.describe_vpc_peering_connections(Filters=s.tag_filters)["VpcPeeringConnections"]
    ours = {p["VpcPeeringConnectionId"] for p in peerings_}
    # The hub VPC: from the hub's CDF security group, or (if bootstrap is already gone)
    # from the hub side of this spoke's peering connections.
    sg = _cdf_group(s)
    hub_vpcs = {sg["VpcId"]} if sg else {p["AccepterVpcInfo"]["VpcId"] for p in peerings_}
    if not hub_vpcs:
        return []
    out = []
    tables = s.hub_ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": sorted(hub_vpcs)}])["RouteTables"]
    for rt in tables:
        for r in rt["Routes"]:
            pcx = r.get("VpcPeeringConnectionId")
            if not pcx:
                continue
            if pcx in ours or (s.vpc_cidr and r.get("DestinationCidrBlock") == s.vpc_cidr and r.get("State") == "blackhole"):
                out.append(item("hub route", f"{rt['RouteTableId']} {r.get('DestinationCidrBlock')}", s.hub_region,
                                f"via {pcx} ({r.get('State')})"))
    return out


CHECKS = [
    pcs_clusters, instances, capacity_reservations, peerings, hub_routes, cdf_rules, vpcs,
    security_groups, addresses, volumes, placement_groups, launch_templates, key_pair, secrets,
    log_groups, kms_keys, buckets, iam_roles, instance_profiles, other_tagged,
]


def check(s):
    """Run the site's checks: (leftovers, errors). A Spoke runs CHECKS; local mode its own list."""
    found, errors = [], []
    for fn in getattr(s, "checks", None) or CHECKS:
        try:
            found += fn(s)
        except Exception as e:  # noqa: BLE001 - reported; one failed check mustn't hide the rest
            errors.append(f"{fn.__name__}: {e}"[:300])
    return found, errors


# -----------------------------------------------------------------------------
# Sweep: remove the leftovers marked auto, in dependency order
# -----------------------------------------------------------------------------


def _try(log, what, fn, *args, **kwargs):
    """Never raises: whatever's left is reported by the check that follows."""
    try:
        fn(*args, **kwargs)
        log.append(f"removed {what}")
    except Exception as e:  # noqa: BLE001
        log.append(f"couldn't remove {what}: {e}"[:300])


def _delete_vpc(s, vpc_id, log):
    """Remove a VPC Terraform no longer tracks, children first."""
    ec2, f = s.ec2, [{"Name": "vpc-id", "Values": [vpc_id]}]
    nats = [n["NatGatewayId"] for n in ec2.describe_nat_gateways(Filter=f)["NatGateways"]
            if n["State"] not in ("deleted", "deleting")]
    for n in nats:
        _try(log, f"NAT gateway {n}", ec2.delete_nat_gateway, NatGatewayId=n)
    if nats:
        _try(log, "wait for NAT gateway deletion", ec2.get_waiter("nat_gateway_deleted").wait,
             NatGatewayIds=nats, WaiterConfig={"Delay": 15, "MaxAttempts": 40})
    for e in ec2.describe_vpc_endpoints(Filters=f)["VpcEndpoints"]:
        _try(log, f"VPC endpoint {e['VpcEndpointId']}", ec2.delete_vpc_endpoints, VpcEndpointIds=[e["VpcEndpointId"]])
    for side in ("requester-vpc-info.vpc-id", "accepter-vpc-info.vpc-id"):
        for p in ec2.describe_vpc_peering_connections(Filters=[{"Name": side, "Values": [vpc_id]}])["VpcPeeringConnections"]:
            if p["Status"]["Code"] not in GONE_PEERING:
                _try(log, f"VPC peering {p['VpcPeeringConnectionId']}", ec2.delete_vpc_peering_connection,
                     VpcPeeringConnectionId=p["VpcPeeringConnectionId"])
    for igw in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}])["InternetGateways"]:
        _try(log, f"internet gateway {igw['InternetGatewayId']} attachment", ec2.detach_internet_gateway,
             InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc_id)
        _try(log, f"internet gateway {igw['InternetGatewayId']}", ec2.delete_internet_gateway,
             InternetGatewayId=igw["InternetGatewayId"])
    for eni in ec2.describe_network_interfaces(Filters=f)["NetworkInterfaces"]:
        if eni["Status"] == "available":
            _try(log, f"network interface {eni['NetworkInterfaceId']}", ec2.delete_network_interface,
                 NetworkInterfaceId=eni["NetworkInterfaceId"])
    for sub in ec2.describe_subnets(Filters=f)["Subnets"]:
        _try(log, f"subnet {sub['SubnetId']}", ec2.delete_subnet, SubnetId=sub["SubnetId"])
    for rt in ec2.describe_route_tables(Filters=f)["RouteTables"]:
        if any(a.get("Main") for a in rt["Associations"]):
            continue
        _try(log, f"route table {rt['RouteTableId']}", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
    _delete_security_groups(s, [g for g in ec2.describe_security_groups(Filters=f)["SecurityGroups"]
                                if g["GroupName"] != "default"], log)
    for acl in ec2.describe_network_acls(Filters=f)["NetworkAcls"]:
        if not acl["IsDefault"]:
            _try(log, f"network ACL {acl['NetworkAclId']}", ec2.delete_network_acl, NetworkAclId=acl["NetworkAclId"])
    _try(log, f"VPC {vpc_id}", ec2.delete_vpc, VpcId=vpc_id)


def _delete_security_groups(s, groups, log):
    # Drop rules first, so groups that reference each other can go.
    for g in groups:
        if g["IpPermissions"]:
            _try(log, f"ingress rules of {g['GroupId']}", s.ec2.revoke_security_group_ingress,
                 GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
        if g["IpPermissionsEgress"]:
            _try(log, f"egress rules of {g['GroupId']}", s.ec2.revoke_security_group_egress,
                 GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
    for g in groups:
        _try(log, f"security group {g['GroupId']}", s.ec2.delete_security_group, GroupId=g["GroupId"])


def _empty_and_delete_bucket(s3, name):
    paginator = s3.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=name):
        objects = [{"Key": o["Key"], "VersionId": o["VersionId"]}
                   for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
        if objects:
            s3.delete_objects(Bucket=name, Delete={"Objects": objects, "Quiet": True})
    s3.delete_bucket(Bucket=name)


def _delete_role(iam, name):
    for p in iam.list_instance_profiles_for_role(RoleName=name)["InstanceProfiles"]:
        iam.remove_role_from_instance_profile(InstanceProfileName=p["InstanceProfileName"], RoleName=name)
    for p in iam.list_attached_role_policies(RoleName=name)["AttachedPolicies"]:
        iam.detach_role_policy(RoleName=name, PolicyArn=p["PolicyArn"])
    for p in iam.list_role_policies(RoleName=name)["PolicyNames"]:
        iam.delete_role_policy(RoleName=name, PolicyName=p)
    iam.delete_role(RoleName=name)


def sweep(s):
    log = []
    by_kind = {}
    for x in check(s)[0]:
        if x["auto"]:
            by_kind.setdefault(x["kind"], []).append(x["id"])

    # PCS first: its node groups would replace instances terminated below.
    for cluster_id in by_kind.get("PCS cluster", []):
        _try(log, f"PCS cluster {cluster_id} teardown", _delete_pcs_cluster, s, cluster_id, log)
    ids = by_kind.get("instance", [])
    if ids:
        _try(log, f"instances {', '.join(ids)}", s.ec2.terminate_instances, InstanceIds=ids)
        _try(log, "wait for instance termination", s.ec2.get_waiter("instance_terminated").wait,
             InstanceIds=ids, WaiterConfig={"Delay": 15, "MaxAttempts": 60})
    for rid in by_kind.get("capacity reservation", []):
        _try(log, f"capacity reservation {rid}", s.ec2.cancel_capacity_reservation, CapacityReservationId=rid)

    for route in by_kind.get("hub route", []):
        rt, cidr = route.split(" ", 1)
        _try(log, f"hub route {route}", s.hub_ec2.delete_route, RouteTableId=rt, DestinationCidrBlock=cidr)
    sg = _cdf_group(s)
    rules = by_kind.get("CDF security group rule", [])
    if sg and rules:
        _try(log, f"CDF rules {', '.join(rules)}", s.hub_ec2.revoke_security_group_ingress,
             GroupId=sg["GroupId"], SecurityGroupRuleIds=rules)
    for pcx in by_kind.get("VPC peering", []):
        _try(log, f"VPC peering {pcx}", s.hub_ec2.delete_vpc_peering_connection, VpcPeeringConnectionId=pcx)

    for vpc_id in by_kind.get("VPC", []):
        _delete_vpc(s, vpc_id, log)
    leftover_groups = by_kind.get("security group", [])
    if leftover_groups:
        try:
            groups = s.ec2.describe_security_groups(GroupIds=leftover_groups)["SecurityGroups"]
        except ClientError:
            groups = []  # went with their VPC
        _delete_security_groups(s, groups, log)
    for alloc in by_kind.get("Elastic IP", []):
        _try(log, f"Elastic IP {alloc}", s.ec2.release_address, AllocationId=alloc)
    for vol in by_kind.get("EBS volume", []):
        _try(log, f"EBS volume {vol}", s.ec2.delete_volume, VolumeId=vol)
    for name in by_kind.get("placement group", []):
        _try(log, f"placement group {name}", s.ec2.delete_placement_group, GroupName=name)
    for lt in by_kind.get("launch template", []):
        _try(log, f"launch template {lt}", s.ec2.delete_launch_template, LaunchTemplateId=lt)

    for name in by_kind.get("key pair", []):
        _try(log, f"key pair {name}", s.ec2.delete_key_pair, KeyName=name)
    sm = s.client("secretsmanager")
    for name in by_kind.get("secret", []):
        _try(log, f"secret {name}", sm.delete_secret, SecretId=name, ForceDeleteWithoutRecovery=True)
    logs = s.client("logs")
    for name in by_kind.get("log group", []):
        _try(log, f"log group {name}", logs.delete_log_group, logGroupName=name)
    kms = s.client("kms")
    for arn in by_kind.get("KMS key", []):
        _try(log, f"KMS key {arn} (scheduled, 7 days)", kms.schedule_key_deletion, KeyId=arn, PendingWindowInDays=7)
    s3 = s.client("s3")
    for name in by_kind.get("S3 bucket", []):
        _try(log, f"S3 bucket {name}", _empty_and_delete_bucket, s3, name)

    for name in by_kind.get("IAM role", []):
        _try(log, f"IAM role {name}", _delete_role, s.iam, name)
    for name in by_kind.get("IAM instance profile", []):
        _try(log, f"IAM instance profile {name}", s.iam.delete_instance_profile, InstanceProfileName=name)
    return log


def run(s, mode, what, report=None, run_id=""):
    """check or sweep then check, print the result, and optionally write the JSON report
    the destroy workflows read. Returns the exit code: 1 if anything is left."""
    removed = sweep(s) if mode == "sweep" else []
    leftovers, errors = check(s)

    for line in removed:
        print(f"  {line}")
    if leftovers:
        print(f"Leftovers from {what}:")
        for x in leftovers:
            note = "" if x["auto"] else "  [needs a person]"
            print(f"  {x['kind']:24} {x['id']}  ({x['where']}) {x['detail']}{note}")
    for e in errors:
        print(f"  couldn't check {e}")
    if not leftovers and not errors:
        print(f"Clean: nothing from {what} is left.")

    if report:
        with open(report, "w") as f:
            json.dump({
                "clean": not leftovers and not errors,
                # Worth another sweep: something left is removable, or a check failed.
                "retryable": any(x["auto"] for x in leftovers) or bool(errors),
                "run_id": run_id, "time": int(time.time()),
                "removed": removed, "leftovers": leftovers, "errors": errors,
            }, f, indent=1)
    return 1 if leftovers or errors else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("mode", choices=["check", "sweep"])
    ap.add_argument("--hub", required=True, help="hub deployment unique name")
    ap.add_argument("--hub-region", required=True)
    ap.add_argument("--region", required=True, help="the spoke's region")
    ap.add_argument("--vpc-cidr", default="", help="the spoke's VPC CIDR (finds hub routes left after its peering is gone)")
    ap.add_argument("--report", help="also write the result as JSON to this file")
    ap.add_argument("--run-id", default="", help="recorded in the report (the destroy build's ID)")
    args = ap.parse_args()
    s = Spoke(args.hub, args.hub_region, args.region, args.vpc_cidr)
    return run(s, args.mode, f"the {args.region} spoke of {args.hub}", args.report, args.run_id)


if __name__ == "__main__":
    sys.exit(main())
