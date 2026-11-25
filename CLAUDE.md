# cnq-path-extender

One-click deployment of a new Cloud Native Qumulo (CNQ) **spoke** cluster in a new AWS
region, peered to an existing **hub** CNQ cluster, with a Cloud Data Fabric portal for a
given path. Full design: [docs/architecture.md](docs/architecture.md).

## Rules

- **Never create, change, or destroy AWS resources.** No `terraform apply`/`destroy`, no
  mutating `aws` CLI calls. The code in this repo creates infrastructure; the user runs it.
  `terraform fmt`, `validate`, and `plan`, and read-only `aws` calls, are fine.
- Commit and push only when asked.

## Stack

- Terraform >= 1.11, S3 backend with `use_lockfile`
- Qumulo Terraform provider (`qumulo_filesystem_aws`), source
  `qumulo-terraform-registry.s3.us-east-1.amazonaws.com/qumulo/qumulo`.
  Reference implementation: https://github.com/Qumulo/qumulo-terraform-aws
- AWS Step Functions orchestrates; CodeBuild runs Terraform; Python Lambdas do portal work
- Portal setup uses the Qumulo REST API (v2 portal endpoints), not Terraform

## Layout

- `bootstrap/` control plane, deployed once per hub
- `spoke/network/` then `spoke/cluster/`: per-region spoke stacks, run in order by CodeBuild
  (split because the Qumulo provider can't plan with values unknown until apply)
- `spoke/pcs/` optional PCS (Slurm) cluster stack, applied after the portal is up; node
  setup in `node/`, pipeline scripts in `pipelines/`
- `spoke/local/` local mode (modules in the hub's VPC): client stack, `build.sh`, `cleanup.py`
- `spoke/cleanup.py` finds and removes anything a spoke left behind (destroy sweep and check)
- `lambdas/portal/` Python Lambda code; `apps/` compute instance applications
- `workflows/` Step Functions definitions (deploy-spoke, destroy-spoke, refresh-hub,
  deploy-local, destroy-local)
- `scripts/` read-only control plane cleanup check
- `docs/` architecture.md, deployment-guide.md, known-issues.md, local-mode.md
