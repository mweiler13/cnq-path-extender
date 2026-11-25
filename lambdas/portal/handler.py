"""Hub/spoke operations for the cnq-path-extender workflows.

One Lambda, dispatched on event["action"]. Runs inside the hub VPC, so it reaches the
hub directly and each spoke over VPC peering. Standard library + boto3 only.

The code is split by module: common (configuration, the Qumulo client, the hub), core
(the spoke lifecycle), portal, placement (where a spoke goes), compute (the optional
compute instance), pcs (the optional PCS cluster's input), and local (local mode).
"""

from common import WorkflowError, begin_invocation
from compute import launch_compute, prepare_compute, terminate_compute
from core import check_health, cleanup_report, forget_spoke, list_spokes, probe_hub, read_spoke, validate
from local import validate_local
from placement import find_capacity, release_capacity
from portal import (
    accept_portal, create_portal, delete_portal, portal_ping, refresh_hub_hosts, verify_portal,
)

ACTIONS = {
    # Core
    "probe_hub": probe_hub,
    "validate": validate,
    "read_spoke": read_spoke,
    "check_health": check_health,
    "cleanup_report": cleanup_report,
    "forget_spoke": forget_spoke,
    "list_spokes": list_spokes,
    # Portal
    "create_portal": create_portal,
    "accept_portal": accept_portal,
    "verify_portal": verify_portal,
    "delete_portal": delete_portal,
    "portal_ping": portal_ping,
    "refresh_hub_hosts": refresh_hub_hosts,
    # Placement
    "find_capacity": find_capacity,
    "release_capacity": release_capacity,
    # Compute
    "launch_compute": launch_compute,
    "prepare_compute": prepare_compute,
    "terminate_compute": terminate_compute,
    # Local mode (docs/local-mode.md)
    "validate_local": validate_local,
}


def handler(event, _context):
    begin_invocation(event)
    action = event.get("action")
    if action not in ACTIONS:
        raise WorkflowError(f"Unknown action: {action}")
    return ACTIONS[action](event)
