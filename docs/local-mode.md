# Local mode

Local mode runs the optional modules (a compute instance, a PCS cluster) **in the hub's
own VPC, mounting the hub directly**: no spoke, no peering, no portal. Use it as the
same-region baseline for work you also run on a spoke in another region, or whenever you
want the modules next to the hub's data.

It uses the same `compute` and `pcs` settings as deploy-spoke (see the
[deployment guide](deployment-guide.md)), and its own two workflows:
`deploy-local-<hub>` and `destroy-local-<hub>`.

## Deploy

Start `deploy-local-<hub>` in the hub's region with the hub path to use and `compute`,
`pcs`, or both. It takes no `region`, `placement` or `vpc_cidr`; other inputs are
rejected.

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <deploy_local_state_machine_arn> --input '{"path": "/my_data", "pcs": {"pipeline": "sarek"}}'
```

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <deploy_local_state_machine_arn> --input '{"path": "/my_data", "compute": {"instance_types": ["g6e.48xlarge"], "application": "parabricks"}}'
```

`deploy_local_state_machine_arn` and `destroy_local_state_machine_arn` are bootstrap
outputs.

What happens:

- **Validate:** the path must be a directory on the hub. Everything is placed in the hub
  nodes' subnet and availability zone, next to the data. At least one of
  `compute.instance_types`, and both PCS instance types, must be offered in that zone.
- **Compute:** a small Terraform stack (`spoke/local/client/`) creates a security group
  (outbound only) and a Session Manager role in the hub VPC. The instance then launches,
  retrying until there's capacity in that zone (local mode makes no capacity
  reservation), and mounts the hub at `/mnt/qumulo`, spreading across the hub's nodes as
  a spoke client does. Setup and applications are the same as on a spoke.
- **PCS:** the same PCS stack as on a spoke (`spoke/pcs/`), given the hub's VPC, subnet
  and node IPs. The same commands (`run-xoos-smoke`, `run-sarek`, `bench-summary`) are on
  the login node. `$PA_DATA` is the hub path, and `$PA_SHARED` is `/pcs` on the hub
  (`/mnt/qumulo/pcs` on the nodes).
- **Email:** summarizes both modules. A failure in one is reported without stopping the
  other, and the execution then ends `FAILED`. Whatever did build stays until
  destroy-local.

One local deployment per hub at a time. Launching again with more (for example, adding
`pcs`) adds to it.

Local mode's resources are tagged `cnq-path-extender:spoke-region = local`. To find the
PCS login node:

```bash
aws ec2 describe-instances --region <hub_region> --filters "Name=tag:cnq-path-extender:role,Values=pcs-login" "Name=tag:cnq-path-extender:hub,Values=<hub_deployment_unique_name>" "Name=tag:cnq-path-extender:spoke-region,Values=local" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text
```

## What it touches on the hub

- **AWS resources:** none of the hub's. The hub's security group already allows NFS from
  its own VPC. Everything local mode creates is tagged `cnq-path-extender:hub = <hub>`
  and `cnq-path-extender:spoke-region = local`, and removal only ever touches resources
  with both tags. The hub cluster carries neither.
- **Load:** local runs read and write the hub directly, from every compute node. Other
  users of the hub share that load; pick a quiet time for large runs.
- **Files on the hub:** a PCS cluster uses `/pcs` on the hub (Nextflow, the container
  cache, work directories), as it uses `/pcs` on a spoke. Results go under the path you
  gave. destroy-local leaves both.

## Remove

Start `destroy-local-<hub>` with `{}`:

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <destroy_local_state_machine_arn> --input '{}'
```

It terminates the compute instance, destroys the PCS stack and then the client stack,
sweeps anything left that carries local mode's tags, and checks. If the check is clean,
it deletes local mode's state files (`<hub>/local/` in the state bucket). Otherwise the
email lists what's left and the execution fails with `LeftoversRemain`. The hub cluster
is never touched.

Remove `/pcs` on the hub by hand when you no longer need it: it can hold large work
directories.

To check by hand (read-only):

```bash
python3 spoke/local/cleanup.py check --hub <hub_deployment_unique_name> --hub-region <hub_region>
```

## How it fits in the code

| Where | What |
|---|---|
| `workflows/deploy-local.asl.json`, `workflows/destroy-local.asl.json` | The two workflows |
| `bootstrap/local.tf` | Their state machines, the Lambda's access to `<hub>/local/`, and the two ARN outputs |
| `lambdas/portal/local.py` | `validate_local`: checks the input, finds the hub nodes' subnet, zone and IPs |
| `spoke/local/client/` | Terraform: security group and Session Manager role in the hub VPC |
| `spoke/local/build.sh` | CodeBuild steps; the buildspec hands over builds with `TF_MODE=local` |
| `spoke/local/cleanup.py` | The removal sweep and check, built on `spoke/cleanup.py` |

The compute instance and PCS code is shared with spokes. Local mode passes a `site` of
`local` (used in names and the `spoke-region` tag) and its own state prefix.
