"""The Cloud Data Fabric portal between the hub and a spoke: create, accept, verify,
diagnose, delete, and point at the hub's current nodes."""

import time
import urllib.parse

from common import PORTAL_TYPE, WorkflowError, hub, hub_ips, hub_uuid, portal_hosts, spoke


def hub_portal_problems(h):
    """The hub's other portal relationships that aren't ACTIVE.

    A relationship that's disconnected (e.g. its peer cluster is stopped) makes the hub
    report missing connections, and its healthy relationships, including the one this
    launch creates, then show DEGRADED until the peer is back. Reported as a warning; it
    doesn't stop the launch.
    """
    problems, unlisted = [], []
    for kind, role, peer_key in (("hubs", "hub", "spoke_cluster_name"), ("spokes", "spoke", "hub_cluster_name")):
        try:
            entries = h.request("GET", f"/v2/portal/{kind}/")["entries"]
        except (WorkflowError, ConnectionError) as e:
            unlisted.append(f"couldn't list the hub's {role} portals: {e}"[:300])
            continue
        for p in entries:
            if p.get("status") != "ACTIVE":
                problems.append(
                    f"hub's {role} portal {p['id']} with {p.get(peer_key) or 'unknown peer'}: "
                    f"{p.get('state')}/{p.get('status')}"
                )
    if problems:
        problems.append(
            "While any of these isn't ACTIVE, the new spoke's portal will likely report DEGRADED "
            "(data still flows). Restore the peer, or delete the relationship without --force."
        )
    return problems + unlisted


def create_portal(event):
    """On the spoke: create the spoke portal and its root, proposing to the hub."""
    s_info, path = event["spoke"], event["launch"]["path"]
    h, s = hub(), spoke(s_info)

    hub_version, spoke_version = h.version(), s.version()
    if hub_version != spoke_version:
        raise WorkflowError(
            f"Version mismatch: hub {hub_version}, spoke {spoke_version}. "
            "Was the hub upgraded during the build?"
        )

    existing = [p for p in s.request("GET", "/v2/portal/spokes/")["entries"] if _is_our_hub(p)]
    portal = existing[0] if existing else s.request(
        "POST", "/v2/portal/spokes/", {"type": PORTAL_TYPE, "hub_hosts": portal_hosts(hub_ips())}
    )

    if not portal.get("roots"):
        # The spoke root's parent directories must exist on the spoke.
        _ensure_parents(s, path)
        portal = s.request(
            "POST",
            f"/v2/portal/spokes/{portal['id']}/roots/",
            {"spoke_root_path": path, "hub_root_path": path},
        )

    return {"spoke_portal_id": portal["id"], "hub_portal_id": portal["hub_id"]}


def _ensure_parents(s, path):
    parts = [p for p in path.split("/") if p][:-1]
    current = "/"
    for name in parts:
        nxt = current.rstrip("/") + "/" + name
        if not s.exists(nxt):
            s.mkdir(current, name)
        current = nxt


def _is_our_hub(spoke_portal):
    if hub_uuid() and spoke_portal.get("hub_cluster_uuid") == hub_uuid():
        return True
    return any(hh["address"] in hub_ips() for hh in spoke_portal.get("hub_hosts", []))


def accept_portal(event):
    """On the hub: accept the relationship and authorize its pending roots.

    The accept request requires authorized_roots (the API rejects it without the field),
    so the spoke's proposed roots are authorized in the same call. Any root still pending
    afterwards (e.g. accepted on an earlier attempt) is authorized individually.
    """
    hub_portal_id = event["portal"]["hub_portal_id"]
    h = hub()
    portal = h.request("GET", f"/v2/portal/hubs/{hub_portal_id}")
    if portal["state"] == "PENDING":
        portal = h.request(
            "POST",
            f"/v2/portal/hubs/{hub_portal_id}/accept",
            {
                "spoke_hosts": portal_hosts(event["spoke"]["primary_ips"]),
                "authorized_roots": portal.get("pending_roots", []),
            },
        )
    for root in portal.get("pending_roots", []):
        ref = urllib.parse.quote(str(root), safe="")
        portal = h.request("POST", f"/v2/portal/hubs/{hub_portal_id}/roots/{ref}")
    return {"state": portal["state"], "authorized_roots": portal.get("authorized_roots", [])}


def verify_portal(event):
    """Spoke portal ACCEPTED and ACTIVE with every root authorized."""
    s = spoke(event["spoke"])
    p = s.request("GET", f"/v2/portal/spokes/{event['portal']['spoke_portal_id']}")
    roots = p.get("roots", [])
    # Accepted with every root authorized: data can flow, even if not all connections
    # are up (DEGRADED). The workflow carries on with a warning if it never gets to ACTIVE.
    usable = p["state"] == "ACCEPTED" and roots and all(r.get("authorized") for r in roots)
    return {
        "ok": bool(usable and p["status"] == "ACTIVE"),
        "usable": bool(usable),
        "state": p["state"],
        "status": p["status"],
        "roots_authorized": [bool(r.get("authorized")) for r in roots],
        "attempt": int(event.get("attempt", 0)) + 1,
    }


def portal_ping(event):
    """Portal connectivity from every node on each side to each host on the other, for the
    deploy summary: the first thing to look at when a portal isn't ACTIVE.

    Best effort (POST /v1/portal/ping, as qq portal_ping uses): never fails the deploy; a
    side that can't be pinged reports why instead.
    """
    s_info = event["spoke"]

    def ping(cluster, hosts):
        try:
            return cluster.request("POST", "/v1/portal/ping", {"hosts": portal_hosts(hosts)})
        except Exception as e:  # noqa: BLE001 - reported, never raised
            return {"error": str(e)[:500]}

    return {
        "spoke_to_hub": ping(spoke(s_info), hub_ips()),
        "hub_to_spoke": ping(hub(), s_info["primary_ips"]),
    }


def delete_portal(event):
    """Remove the relationship on both sides.

    The spoke side is skipped when force is set or when the spoke doesn't answer: the
    spoke is about to be destroyed anyway, so its half of the portal doesn't matter. The
    hub side is then force-deleted so the hub isn't left with a dangling portal.
    """
    s_info, force = event["spoke"], bool(event.get("force"))
    deleted = {"spoke": [], "hub": [], "spoke_skipped": None}

    if force:
        deleted["spoke_skipped"] = "force requested"
    else:
        s = spoke(s_info)
        try:
            entries = s.request("GET", "/v2/portal/spokes/")["entries"]
        except ConnectionError as e:
            # Fail fast rather than letting the workflow retry an unreachable spoke.
            force = True
            deleted["spoke_skipped"] = f"spoke unreachable: {e}"[:300]
        else:
            for p in entries:
                if _is_our_hub(p):
                    s.request("DELETE", f"/v2/portal/spokes/{p['id']}")
                    deleted["spoke"].append(p["id"])
            _wait_until(lambda: not any(_is_our_hub(p) for p in s.request("GET", "/v2/portal/spokes/")["entries"]))

    h = hub()
    spoke_ips = set(s_info["primary_ips"])

    def ours(p):
        return any(sh["address"] in spoke_ips for sh in p.get("spoke_hosts", []))

    for p in h.request("GET", "/v2/portal/hubs/")["entries"]:
        if ours(p):
            suffix = "?force=true" if force else ""
            h.request("DELETE", f"/v2/portal/hubs/{p['id']}{suffix}")
            deleted["hub"].append(p["id"])
    _wait_until(lambda: not any(ours(p) for p in h.request("GET", "/v2/portal/hubs/")["entries"]))
    return deleted


# Two waits (spoke, hub) must fit inside the 15-minute Lambda limit.
def _wait_until(condition, timeout=360, interval=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return
        time.sleep(interval)
    raise WorkflowError(f"Timed out after {timeout}s waiting for portal deletion.")


def refresh_hub_hosts(event):
    """refresh-hub: point this region's spoke portal at the hub's current nodes.

    Replacing the hub's nodes (e.g. changing their instance type) gives them new IPs, and a
    spoke portal keeps trying the old ones until it's told. The relationship is found by
    the hub's UUID, since its recorded addresses are the stale ones. A spoke that doesn't
    exist, or has no cluster, is skipped.
    """
    from core import read_spoke  # core imports this module

    region, ips = event["region"], hub_ips()
    try:
        s_info = read_spoke({"region": region})
    except WorkflowError as e:
        return {"region": region, "result": "skipped", "detail": str(e)[:300]}
    if not s_info["has_cluster"]:
        return {"region": region, "result": "skipped", "detail": "the spoke has no cluster"}

    s = spoke(s_info)
    changed, current = [], []
    for p in s.request("GET", "/v2/portal/spokes/")["entries"]:
        if not _is_our_hub(p):
            continue
        before = sorted(h["address"] for h in p.get("hub_hosts", []))
        if before == ips:
            current.append(p["id"])
            continue
        s.request("PATCH", f"/v2/portal/spokes/{p['id']}", {"hub_hosts": portal_hosts(ips)})
        changed.append({"portal": p["id"], "from": before, "to": ips})
    if not changed and not current:
        return {"region": region, "result": "skipped", "detail": "no portal to this hub on the spoke"}

    # The portal reconnects on its own; report where it stands right after the change.
    time.sleep(30 if changed else 0)
    status = [
        {k: q.get(k) for k in ("id", "state", "status")}
        for q in s.request("GET", "/v2/portal/spokes/")["entries"] if _is_our_hub(q)
    ]
    return {
        "region": region,
        "result": "updated" if changed else "already current",
        "changed": changed,
        "portal_status": status,
    }
