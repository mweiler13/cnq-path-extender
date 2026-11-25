#!/usr/bin/env python3
"""Find, and optionally remove, what local mode left in the hub's region.

    local/cleanup.py check --hub H --hub-region R [--report FILE]
    local/cleanup.py sweep --hub H --hub-region R [--report FILE]

Uses spoke/cleanup.py's checks, limited to what local mode creates (PCS cluster,
instances, launch templates, security groups, volumes, IAM roles and profiles), on
resources tagged cnq-path-extender:hub = H and
cnq-path-extender:spoke-region = local. The hub cluster carries neither tag, so it's
never touched.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import cleanup  # noqa: E402  (spoke/cleanup.py)

SITE = "local"


class Local(cleanup.Spoke):
    def __init__(self, hub, hub_region):
        super().__init__(hub, hub_region, hub_region, "")
        # "local" in tags and names; AWS calls still go to the hub's region.
        self.region = SITE
        self.prefix = "spk" + SITE
        self.tag_filters = [
            {"Name": "tag:cnq-path-extender:hub", "Values": [hub]},
            {"Name": "tag:cnq-path-extender:spoke-region", "Values": [SITE]},
        ]

    # Only what local mode creates; the hub's own resources carry neither tag anyway.
    checks = [
        cleanup.pcs_clusters, cleanup.instances, cleanup.launch_templates,
        cleanup.security_groups, cleanup.volumes, cleanup.buckets, cleanup.iam_roles,
        cleanup.instance_profiles, cleanup.other_tagged,
    ]

    def client(self, service, region=None):
        return cleanup.boto3.client(service, region_name=region or self.hub_region)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("mode", choices=["check", "sweep"])
    ap.add_argument("--hub", required=True, help="hub deployment unique name")
    ap.add_argument("--hub-region", required=True)
    ap.add_argument("--report", help="also write the result as JSON to this file")
    ap.add_argument("--run-id", default="", help="recorded in the report (the destroy build's ID)")
    args = ap.parse_args()
    s = Local(args.hub, args.hub_region)
    return cleanup.run(s, args.mode, f"local mode of {args.hub}", args.report, args.run_id)


if __name__ == "__main__":
    sys.exit(main())
