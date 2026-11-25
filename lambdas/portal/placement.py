"""Where a new spoke goes: region and zone checks, the vCPU quota check, the search
across regions, and the capacity hunt (On-Demand Capacity Reservations) for a compute
instance."""

import concurrent.futures
import datetime
import socket
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from common import EXTRA_TAGS, HUB_NAME, HUB_REGION, WorkflowError, regional

# On-Demand vCPU quotas (Service Quotas codes) by instance family prefix, checked in
# order: no prefix may shadow a later one (the first match wins).
VCPU_QUOTAS = [
    ("inf", "L-1945791B", "Inf"), ("trn", "L-2C3B7624", "Trn"), ("dl", "L-6E869C2A", "DL"),
    ("vt", "L-DB2E81BA", "G and VT"), ("g", "L-DB2E81BA", "G and VT"), ("p", "L-417A185B", "P"),
    ("f", "L-74FC7D96", "F"), ("x", "L-7295265B", "X"),
]
STANDARD_QUOTA = ("L-1216C47A", "Standard (A, C, D, H, I, M, R, T, Z)")
PROVISIONER_VCPUS = 4  # the m5.xlarge the Qumulo provider runs while creating a cluster

# Capacity reservations for the compute instance: held this long, tagged with this role.
RESERVATION_HOURS = 3
RESERVATION_ROLE = "compute-capacity"
# Refusals that waiting may fix; anything else (e.g. permissions) won't.
CAPACITY_ERRORS = {
    "InsufficientInstanceCapacity", "InsufficientCapacity", "InsufficientHostCapacity",
    "ReservationCapacityExceeded", "InstanceLimitExceeded", "VcpuLimitExceeded", "Unsupported",
}


def latency_from_hub(regions):
    """{region: ms} to each region's EC2 endpoint from here (the hub's VPC): the best of
    three TCP connects, None if it doesn't answer. Measured in parallel, a few seconds."""

    def measure(region):
        best = None
        for _ in range(3):
            start = time.monotonic()
            try:
                socket.create_connection((f"ec2.{region}.amazonaws.com", 443), timeout=3).close()
            except OSError:
                continue
            ms = round((time.monotonic() - start) * 1000)
            best = ms if best is None else min(best, ms)
        return best

    regions = list(regions)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        return dict(zip(regions, pool.map(measure, regions)))


def _standard_zones(ec2):
    zones = ec2.describe_availability_zones(
        Filters=[
            {"Name": "opt-in-status", "Values": ["opt-in-not-required"]},
            {"Name": "state", "Values": ["available"]},
        ]
    )["AvailabilityZones"]
    return {z["ZoneName"] for z in zones}


def _offerings(ec2, types):
    """{zone: {instance types offered there}} for the given types."""
    found = {}
    pages = ec2.get_paginator("describe_instance_type_offerings").paginate(
        LocationType="availability-zone", Filters=[{"Name": "instance-type", "Values": list(types)}]
    )
    for page in pages:
        for o in page["InstanceTypeOfferings"]:
            found.setdefault(o["Location"], set()).add(o["InstanceType"])
    return found


def check_az(region, cnq_type, az):
    ec2 = boto3.client("ec2", region_name=region)
    ok = sorted(_standard_zones(ec2) & {z for z, t in _offerings(ec2, [cnq_type]).items() if cnq_type in t})
    if az not in ok:
        raise WorkflowError(f"availability_zone {az} doesn't offer {cnq_type}. Zones that do: {', '.join(ok)}.")
    return az


def _cluster_fit_problem(region, cnq_type, node_count, ec2=None, sq=None):
    """Why the cluster can't be built in this region, or None if it can: the region must
    offer the cluster's instance type, and its On-Demand vCPU quota must have room for the
    nodes plus the provisioner, after what's already running."""
    ec2 = ec2 or boto3.client("ec2", region_name=region)
    sq = sq or boto3.client("service-quotas", region_name=region)
    if not _standard_zones(ec2) & {z for z, t in _offerings(ec2, [cnq_type]).items() if cnq_type in t}:
        return f"No availability zone in {region} offers {cnq_type}."
    vcpus = ec2.describe_instance_types(InstanceTypes=[cnq_type])["InstanceTypes"][0]["VCpuInfo"]["DefaultVCpus"]
    need = node_count * vcpus + PROVISIONER_VCPUS
    code, label = _vcpu_quota(cnq_type)
    limit = _quota(sq, code)
    used = _vcpus_in_use(ec2, code)
    if limit - used < need:
        return (
            f"Not enough On-Demand {label} vCPU quota in {region}: this spoke needs {need} "
            f"({node_count} x {cnq_type} at {vcpus} vCPUs, plus {PROVISIONER_VCPUS} for the provisioner "
            f"while it's built), and {limit - used:g} of {limit:g} are free ({used} in use). Request an "
            "increase in Service Quotas, stop other instances, or launch fewer or smaller nodes."
        )
    return None


def check_cluster_fits(region, cnq_type, node_count):
    problem = _cluster_fit_problem(region, cnq_type, node_count)
    if problem:
        raise WorkflowError(problem)


def first_region_that_fits(search, cnq_type, node_count):
    """placement without compute: the first region, in search order, that the cluster fits.
    Returns (region or "", {skipped region: reason})."""
    clients = {r: (regional("ec2", r), regional("service-quotas", r)) for r in search}

    def check(region):
        try:
            return _cluster_fit_problem(region, cnq_type, node_count, *clients[region])
        except ClientError as e:
            return f"couldn't check: {e.response['Error']['Code']}"
        except BotoCoreError as e:
            return f"didn't answer: {type(e).__name__}"

    # In parallel, as for the capacity hunt's candidates; the search order decides.
    skipped = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        for region, problem in zip(search, pool.map(check, search)):
            if not problem:
                return region, skipped
            skipped[region] = problem
    return "", skipped


def _vcpus_in_use(ec2, code):
    """vCPUs of running On-Demand instances that count against this quota."""
    used = 0
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["pending", "running"]}]
    )
    for page in pages:
        for r in page["Reservations"]:
            for i in r["Instances"]:
                if i.get("InstanceLifecycle") == "spot" or _vcpu_quota(i["InstanceType"])[0] != code:
                    continue
                cpu = i.get("CpuOptions", {})
                used += cpu.get("CoreCount", 0) * cpu.get("ThreadsPerCore", 1)
    return used


def _vcpu_quota(itype):
    for prefix, code, label in VCPU_QUOTAS:
        if itype.startswith(prefix):
            return code, label
    return STANDARD_QUOTA


def _quota(sq, code):
    try:
        return sq.get_service_quota(ServiceCode="ec2", QuotaCode=code)["Quota"]["Value"]
    except ClientError:
        return sq.get_aws_default_service_quota(ServiceCode="ec2", QuotaCode=code)["Quota"]["Value"]


def capacity_candidates(search, cnq_type, node_count, compute, requested_az):
    """Zones the capacity hunt may try, region by region in search order.

    A zone qualifies if it offers the cluster's type and at least one compute type, and
    the region's On-Demand vCPU quotas fit the cluster and that type (quota limits only;
    instances already running against them aren't counted). Returns (candidates,
    {skipped region: reason}).
    """
    types = list(dict.fromkeys([cnq_type, *compute["instance_types"]]))
    vcpus = {
        i["InstanceType"]: i["VCpuInfo"]["DefaultVCpus"]
        for i in boto3.client("ec2", region_name=HUB_REGION).describe_instance_types(InstanceTypes=types)["InstanceTypes"]
    }
    cnq_need = node_count * vcpus[cnq_type] + PROVISIONER_VCPUS
    clients = {r: (regional("ec2", r), regional("service-quotas", r)) for r in search}

    def check(region):
        """(candidate, None) or (None, why it's skipped)."""
        try:
            ec2, sq = clients[region]
            code, label = _vcpu_quota(cnq_type)
            have = _quota(sq, code)
            if have < cnq_need:
                return None, f"{label} vCPU quota {have:g} < {cnq_need} for the cluster"
            fits, short = [], []
            for t in compute["instance_types"]:
                code, label = _vcpu_quota(t)
                have = _quota(sq, code)
                if have >= vcpus[t]:
                    fits.append(t)
                else:
                    short.append(f"{t} ({label} quota {have:g} < {vcpus[t]})")
            if not fits:
                return None, "vCPU quota too low for " + ", ".join(short)
            offered = _offerings(ec2, types)
            zones = []
            for az in sorted(_standard_zones(ec2)):
                if requested_az and az != requested_az:
                    continue
                here = offered.get(az, set())
                usable = [t for t in fits if t in here]
                if cnq_type in here and usable:
                    zones.append({"availability_zone": az, "instance_types": usable})
            if not zones:
                where = requested_az or "any zone"
                return None, f"{where} doesn't offer both {cnq_type} and one of {', '.join(fits)}"
            return {"region": region, "zones": zones}, None
        except ClientError as e:
            return None, f"couldn't check: {e.response['Error']['Code']}"
        except BotoCoreError as e:
            return None, f"didn't answer: {type(e).__name__}"

    # In parallel: a few calls per region, and an unresponsive region costs its timeouts
    # once instead of adding to every other region's. Results keep the search order.
    candidates, skipped = [], {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        for region, (candidate, why) in zip(search, pool.map(check, search)):
            if candidate:
                candidates.append(candidate)
            else:
                skipped[region] = why
    return candidates, skipped


def _reservations(region, states=("active", "pending")):
    ec2 = regional("ec2", region)
    resp = ec2.describe_capacity_reservations(
        Filters=[
            {"Name": "tag:cnq-path-extender:hub", "Values": [HUB_NAME]},
            {"Name": "tag:cnq-path-extender:role", "Values": [RESERVATION_ROLE]},
            {"Name": "state", "Values": list(states)},
        ]
    )
    return resp["CapacityReservations"]


def cancel_reservations(region):
    ec2 = regional("ec2", region)
    ids = [r["CapacityReservationId"] for r in _reservations(region)]
    for rid in ids:
        try:
            ec2.cancel_capacity_reservation(CapacityReservationId=rid)
        except ClientError as e:
            if e.response["Error"]["Code"] not in ("InvalidCapacityReservationId.NotFound", "IncorrectState"):
                raise
    return ids


def find_capacity(event):
    """One round of reservation requests across the candidate zones. Never raises for
    no-capacity-yet: returns found, gave_up, or neither (wait and call again)."""
    launch, hunt = event["launch"], event.get("hunt") or {}
    compute = launch["compute"]
    attempt = int(hunt.get("attempt", 0)) + 1
    deadline = int(hunt.get("deadline") or time.time() + compute["give_up_after_hours"] * 3600)
    result = {
        "found": False, "gave_up": False, "attempt": attempt, "deadline": deadline,
        "wait_seconds": compute["retry_minutes"] * 60, "region": None, "availability_zone": None,
        "instance_type": None, "reservation_id": None, "last_errors": [],
    }

    def found(region, r):
        result.update(
            found=True, region=region, availability_zone=r["AvailabilityZone"],
            instance_type=r["InstanceType"], reservation_id=r["CapacityReservationId"],
        )
        return result

    # A reservation from an earlier round (a retried call, or a re-run) is ours to use.
    unreachable = set()
    for c in launch["candidates"]:
        try:
            held = _reservations(c["region"])
        except BotoCoreError as e:
            unreachable.add(c["region"])
            result["last_errors"].append(f"{c['region']}: didn't answer ({type(e).__name__})")
            continue
        if held:
            return found(c["region"], held[0])
    if time.time() > deadline:
        result["gave_up"] = True
        return result

    end = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=RESERVATION_HOURS)
    refused = other_errors = 0  # requests the regions refused; of those, not for capacity
    for c in launch["candidates"]:
        region = c["region"]
        if region in unreachable:
            continue
        ec2 = regional("ec2", region)
        tags = [
            {"Key": k, "Value": v}
            for k, v in {
                **EXTRA_TAGS,
                "Name": f"{HUB_NAME}-{region}-compute",
                "cnq-path-extender:hub": HUB_NAME,
                "cnq-path-extender:spoke-region": region,
                "cnq-path-extender:role": RESERVATION_ROLE,
            }.items()
        ]
        for az, itype in [(z["availability_zone"], t) for z in c["zones"] for t in z["instance_types"]]:
            try:
                r = ec2.create_capacity_reservation(
                    InstanceType=itype,
                    InstancePlatform="Linux/UNIX",
                    AvailabilityZone=az,
                    InstanceCount=1,
                    InstanceMatchCriteria="targeted",
                    EndDateType="limited",
                    EndDate=end,
                    TagSpecifications=[{"ResourceType": "capacity-reservation", "Tags": tags}],
                    ClientToken=f"{deadline}-{attempt}-{az}-{itype}"[:64],
                )["CapacityReservation"]
            except BotoCoreError as e:
                # The region isn't answering; skip the rest of it this round.
                result["last_errors"].append(f"{region}: didn't answer ({type(e).__name__})")
                break
            except ClientError as e:
                code = e.response["Error"]["Code"]
                refused += 1
                other_errors += code not in CAPACITY_ERRORS
                if len(result["last_errors"]) < 50:
                    result["last_errors"].append(f"{az} {itype}: {code}")
                continue
            return found(region, r)

    # Every refusal being for a reason other than capacity (e.g. permissions) won't fix
    # itself by waiting.
    if refused and other_errors == refused:
        raise WorkflowError(f"Capacity reservation requests failed: {'; '.join(result['last_errors'][:10])}")
    return result


def release_capacity(event):
    """On a failed deploy: cancel any reservation still held, so it isn't billed until it
    expires. Looks in every region the launch could have reserved in."""
    launch = (event.get("state") or {}).get("launch") or {}
    regions = {c["region"] for c in launch.get("candidates") or []}
    if launch.get("region"):
        regions.add(launch["region"])
    cancelled, failed = [], []
    for region in sorted(regions):
        try:
            cancelled += cancel_reservations(region)
        except (BotoCoreError, ClientError) as e:
            failed.append(f"{region}: {e}"[:200])  # the reservation's end date is the backstop
    return {"cancelled": cancelled, "failed": failed}
