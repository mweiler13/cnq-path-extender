# Architecture

How cnq-path-extender is built and why. For setup and day-to-day use, see the
[deployment guide](deployment-guide.md).

## Goal

Given an existing **hub** CNQ cluster in AWS (fixed when the control plane is deployed),
a **target region** (and optionally an availability zone), a **path** on the hub, and a
**VPC CIDR**, one action builds a new **spoke** CNQ cluster in that region, connects the
two networks, and links the clusters with a Cloud Data Fabric (CDF) portal for that path.
The path's data is then readable and writable in the spoke region without copying it in
advance. A matching action removes everything the first one created and checks that
nothing is left.

```json
{
  "region": "eu-central-1",
  "path": "/my_data",
  "vpc_cidr": "10.20.0.0/16"
}
```

The tool sets up environments and stops there. It never runs a workload.

## Layers

1. **Control plane** (`bootstrap/`): deployed once per hub, in the hub's account and
   region, by a person running `terraform apply`.
2. **Spoke stacks** (`spoke/`): deployed per region by the control plane, never by hand.

### Control plane

| Piece | Name | What it does |
|---|---|---|
| Step Functions state machines | `deploy-spoke-<hub>`, `destroy-spoke-<hub>`, `refresh-hub-<hub>`, `deploy-local-<hub>`, `destroy-local-<hub>` | The five workflows (below) |
| CodeBuild project | `spoke-build-<hub>` | Runs Terraform for the spoke stacks (and local mode's), and the cleanup sweep |
| Lambda function | `cnq-path-extender-<hub>` | Input checks, placement, Qumulo REST calls (portal create, accept, verify), compute instance launch. Runs in the hub VPC. |
| SNS topic | `cnq-path-extender-<hub>` | Success and failure emails |
| CDF security group | `cdf-<hub>` | In the hub VPC; attached to the hub once. Each spoke adds its own TCP 3713 rule to it. |
| Lambda security group | `cnq-path-extender-lambda-<hub>` | The Lambda's own group in the hub VPC |
| Code bundle | `s3://<state_bucket>/<hub>/bundle/spoke.zip` | A zip of `spoke/`, uploaded on every bootstrap apply. CodeBuild runs this copy. |
| IAM roles, log groups | `cnq-path-extender-*-<hub>`, `/aws/lambda/...`, `/aws/codebuild/...` | For the above |

The Terraform state bucket is **not** created by bootstrap. It's an existing bucket you
name in `state_bucket`. Bootstrap's own state, the spoke states, and the code bundle all
live in it under `<hub>/`.

### Spoke stacks

Three Terraform stacks with separate state, applied in order by CodeBuild:

| Stack | State key | What it builds |
|---|---|---|
| `spoke/network/` | `<hub>/spokes/<region>/network.tfstate` | VPC with a private subnet (the cluster) and a public subnet (NAT gateway); internet gateway; S3 gateway endpoint; cross-region VPC peering, requested from the spoke and accepted in the hub region; routes both ways; the TCP 3713 rule on the hub's CDF group; the spoke admin password and an SSH key pair, both in Secrets Manager; optionally client resources (security group and Session Manager role). Uses two AWS providers: the spoke region, and an alias for the hub region. |
| `spoke/cluster/` | `<hub>/spokes/<region>/cluster.tfstate` | The CNQ cluster (`qumulo_filesystem_aws`), at the hub's exact Qumulo Core version, with `allow_cidrs` covering the spoke VPC and the hub VPC. Reads the network's outputs with `terraform_remote_state`. |
| `spoke/pcs/` | `<hub>/spokes/<region>/pcs.tfstate` | Optional. An AWS PCS (Slurm) cluster in the spoke's private subnet. |

The network and cluster are separate stacks because the Qumulo provider can't plan with
values that are unknown until apply (such as a subnet ID created in the same run). The
cluster is planned only once its network exists.

`spoke/cleanup.py` finds, and on destroy removes, anything a spoke left behind.

## Modules

The core always runs. Everything else is off unless its key is in the launch input. A
launch with only the core inputs creates nothing the core doesn't need.

| Module | Turned on by | Workflow steps | Terraform | Lambda code |
|---|---|---|---|---|
| Core | always | Validate, build network, build cluster, wait healthy, portal create, accept, verify, notify | `spoke/network/`, `spoke/cluster/` | `core.py`, `portal.py` |
| Placement | `placement`, or `compute` on a new spoke | In Validate; with compute, the capacity hunt | none | `placement.py` |
| Client resources | `client_resources` or `compute` | Part of the network build | client security group and instance role (`count`) | none |
| Compute instance | `compute` | Reserve capacity, launch (alongside the cluster build), mount once the portal is up | none | `compute.py` |
| Application | `compute.application` | none: runs on the instance at boot | none | one script per application in `apps/` |
| PCS cluster | `pcs` | Build PCS, after the portal is up | `spoke/pcs/` | `pcs.py` (input check only) |
| Pipeline | `pcs.pipeline` | none: runs on the login node at boot | one script per pipeline in `spoke/pcs/pipelines/` | none |
| Local mode | `deploy-local` | Its own two workflows | `spoke/local/client/`, `spoke/pcs/` | `local.py` |

Each module is a Choice-gated branch of `deploy-spoke`. A missing key skips the branch,
including all of its AWS calls: no reservations, no launches. Destroy stays one workflow
and removes whatever exists, found by tag.

`handler.py` is only the action dispatch. `common.py` holds the configuration, the
Qumulo REST client and the hub lookups. Each module's code is in its own file.

## Key decisions

| Topic | Decision |
|---|---|
| CNQ deployment | The Qumulo Terraform provider (`qumulo_filesystem_aws`) |
| Orchestration | Step Functions. Terraform runs in CodeBuild; REST and EC2 calls run in the Lambda. |
| Hub | An existing CNQ cluster in AWS. One control plane per hub. |
| Hub-spoke network | Cross-region VPC peering, to a new VPC per spoke |
| Spoke VPC CIDR | Given per launch; checked against the hub VPC and every VPC peered with it |
| Credentials | Secrets Manager: the hub's existing admin secret, and a generated secret per spoke |
| Terraform state | An existing S3 bucket, native locking (`use_lockfile`), separate state per stack |
| Portal path | The same path on hub and spoke |
| Spoke software version | Always the hub's exact Qumulo Core version, read from the hub at run time. Never "latest". |
| Code source for CodeBuild | A zip of `spoke/` uploaded by bootstrap. No link to a Git repository: to change what spokes run, edit your copy and re-apply bootstrap. |
| Failure handling | Email the failure. Never auto-destroy. A re-run with the same inputs resumes. |
| Portal setup | Qumulo REST API (v2 portal endpoints), not Terraform |
| Compute instance | Lambda `RunInstances` in a retry loop, not Terraform: capacity for large types can be unavailable for hours. |
| PCS cluster | Terraform (`hashicorp/aws` plus `hashicorp/awscc`, since PCS is only in the Cloud Control provider) |

### Version matching

The provider installs Qumulo Core itself, and `cluster_version` picks which one. Spokes
must run the hub's version, so `spoke/cluster/` makes `cluster_version` required with no
default. Validate reads the hub's version from `GET /v1/version` (for example
`Qumulo Core 7.10.1.1` becomes `7.10.1.1`), and the Portal step checks again before
creating the portal, in case the hub was upgraded during the build. A spoke's version is
fixed at creation; later hub upgrades must be applied to spokes by hand.

### Compute instance

- **Launch.** The Lambda calls `RunInstances`, and the workflow loops (a Wait state)
  until it succeeds or `give_up_after_hours` passes. The instance is found by tag
  (`cnq-path-extender:role = compute`), so each attempt is idempotent, and destroy-spoke
  can find it.
- **Image.** Chosen per instance type at launch from AWS's public SSM parameters: Amazon
  Linux 2023 for the type's architecture, or the Deep Learning Base OSS NVIDIA Driver GPU
  AMI when the type has GPUs. A custom `ami_id` replaces both. `compute/base.sh` handles
  `dnf` and `apt-get` images, finds the login user, and stripes NVMe instance storage
  into a scratch directory.
- **Alongside the cluster.** A Parallel state runs the cluster build and portal next to
  the compute launch. A compute failure is caught inside its branch and reported in the
  summary, so it can't stop the cluster's CodeBuild run mid-apply.
- **Finding capacity.** For a new spoke with a compute instance, the workflow requests a
  one-instance On-Demand Capacity Reservation in each candidate zone in turn before
  building anything. A failed request costs nothing; a successful one holds the capacity
  and decides the spoke's region and zone. The instance then launches into the
  reservation, and the reservation is cancelled. Reservations are tagged
  `cnq-path-extender:role = compute-capacity`, end after 3 hours as a backstop, and are
  cancelled by the failure path, by a failed compute launch, and by destroy-spoke.
  Only the compute instance is reserved; an existing spoke keeps its region and zone.
- **Region order.** With `placement: {}`, regions are sorted by TCP connect time from the
  hub's VPC to each region's EC2 endpoint (best of three). It's measured rather than
  looked up, so it follows the real network and needs no table of regions.
- **Mount handoff.** The instance can start before the cluster has IPs. Its user data
  installs a service that reads the instance's own tags through instance metadata and
  mounts once the workflow sets `cnq-path-extender:nfs-hosts`. The instance needs no IAM
  permission for this. Side effect: `extra_tags` keys must use only the characters
  instance metadata allows.
- **Applications.** One shell file per application in `lambdas/portal/apps/`, appended
  to `lambdas/portal/compute/base.sh` in the user data. Adding a file adds an
  application.

### PCS cluster

- **Built last.** `spoke/pcs/` is applied after the portal is active: its nodes mount
  the spoke at boot, so the spoke's IPs and the portal path must exist. Destroy runs it
  first, and only when its state holds resources (its data sources fail where PCS isn't
  offered).
- **Layout.** A cluster (size Small, Slurm 25.11), a `login` node group fixed at one
  instance, a `compute` node group from 0 to `max_nodes` (idle nodes stop after
  `idle_minutes`), and one queue, `compute`. One launch template per node group; the
  login node's also carries the pipeline script.
- **Image.** AWS's PCS sample AMI for the Slurm version (Amazon Linux 2023, x86_64, with
  the PCS agent). AWS doesn't support it for production. The node role is under the
  `/aws-pcs/` path, as PCS requires.
- **Node setup** (`spoke/pcs/node/setup.sh`, as MIME user data, because PCS merges its
  own). It runs before the PCS agent, so a node joins Slurm only when ready. Every node:
  Java 17, Python 3.12, Apptainer, Slurm on `PATH`, and the spoke mount, spread evenly
  across the spoke's nodes. The login node then installs Nextflow and the pipeline in
  the background on shared storage, writes `pcs.config`, and installs `bench-summary`
  and `bench-steps`. PCS caps user data at 13,384 bytes, so Terraform compresses the
  scripts and strips their comment lines, and a precondition fails the plan if a node's
  user data is still too big.
- **Root squashing.** A CNQ NFS export can map root to `nobody`, so node setup creates
  only the shared directory itself as root (mode 1777). Everything under it is created
  by `ec2-user`, who runs every job.
- **Container caches.** Finished images are shared on the cluster; Apptainer's own layer
  cache and build space stay on each node's local disk.
- **Node settings for PCS:** Slurm outside the default
  `PATH`, only physical cores visible to Slurm, Apptainer with `--userns`, Nextflow's
  home and the container cache on shared storage, and Python 3.12 on every node for the
  Xoos launcher's driver job.

## Workflows

All five run in the hub's region. Every one ends with an email. A notify step that fails
can't fail a run whose work finished: the run still ends in success, and the failure to
send is recorded in the execution.

### deploy-spoke

Input: `path`, `vpc_cidr`, and `region` or `placement`; optional sizing,
`availability_zone`, `client_resources`, `compute` and `pcs`. Unknown top-level inputs
are rejected.

1. **Validate** (Lambda). Checks every input, confirms the hub still reports the cluster
   UUID recorded at bootstrap, confirms `path` is a directory on the hub, checks
   `vpc_cidr` against the hub VPC and every VPC peered with it, and reads the hub's
   version. For a new spoke, checks that the region (or zone) offers the instance type
   and has On-Demand vCPU quota for the nodes plus the provisioner. With `placement`,
   picks the region. Lists the hub's portal relationships that aren't ACTIVE as
   warnings. If the region already has a spoke of this hub with the same inputs, the run
   resumes it; different inputs are refused.
2. **Find capacity** (Lambda and a wait loop). Only for a new spoke with `compute`.
3. **Build network** (CodeBuild: `spoke/network/`).
4. In parallel:
   - **Build cluster** (CodeBuild: `spoke/cluster/`), **wait healthy** (every node
     ACTIVE, up to 90 minutes), **create portal** on the spoke and propose it to the
     hub, **accept** it on the hub and authorize the path, **verify** (ACTIVE, or
     accepted and authorized but DEGRADED, reported as a warning), and a node-by-node
     **portal ping** for the summary.
   - **Launch compute** (Lambda and a wait loop), only with `compute`.
5. **Mount compute** (Lambda): tags the instance with the spoke's node IPs.
6. **Build PCS** (CodeBuild: `spoke/pcs/`), only with `pcs`.
7. **Notify** (SNS). On failure: release any capacity reservation still held, then email
   which step failed and why. Nothing is torn down.

### destroy-spoke

Input: `region`, optional `force`.

1. **Read spoke** (Lambda): reads the spoke's state, and refuses if any spoke cluster
   instance is stopped.
2. **Terminate compute** (Lambda): terminates the compute instance and cancels any
   capacity reservation.
3. **Delete portal** (Lambda), if the cluster exists: on the spoke and on the hub. With
   `force`, or if the spoke doesn't answer, it skips the spoke side and force-deletes
   the hub side.
4. **Destroy** (CodeBuild): see "Removal" below.
5. **Read cleanup report** (Lambda). If clean, **forget the spoke**: delete its files
   in the state bucket. Otherwise email the leftovers and fail with `LeftoversRemain`.

### refresh-hub

Input: `{}` for every spoke of this hub, or `{"region": "..."}` for one.

Replacing the hub's nodes gives them new IPs. The control plane follows on its own: the
Lambda looks up the hub's nodes by their `Qumulo-Cluster` tag on every run. Spoke portals
don't. refresh-hub lists this hub's spokes from their state files and, for each one, finds
its portal to the hub by the hub's cluster UUID and updates its hub addresses
(`PATCH /v2/portal/spokes/{id}`) if they're out of date. One spoke failing doesn't stop
the others; the email lists each result.

### deploy-local

Input: `path`, and `compute` and/or `pcs`. Unknown inputs are rejected.

Runs the compute instance and PCS modules in the hub's own VPC, mounting the hub
directly. No spoke, no peering, no portal. See [local mode](local-mode.md).

1. **Validate local** (Lambda): checks the input and the path, and finds the hub nodes'
   subnet, zone and IPs. The instance types must be offered in that zone.
2. In parallel, each branch reporting its own failure:
   - **Compute:** build the client stack (`spoke/local/client/`: a security group and
     Session Manager role in the hub VPC), launch the instance (retrying in that zone
     until there's capacity; no capacity reservation), and tag it with the hub's node
     IPs so it mounts the hub.
   - **PCS:** apply `spoke/pcs/` with the hub's VPC, subnet and node IPs passed in.
3. **Notify.** If either branch failed, the email says which and the run fails. What did
   build stays until destroy-local.

### destroy-local

Input: `{}`.

Terminates the compute instance, destroys the PCS stack and then the client stack,
sweeps anything left that carries local mode's tags (`spoke/local/cleanup.py`), checks,
and if clean deletes local mode's state files. The hub cluster is never touched.

## Removal

destroy-spoke removes everything a launch can create.

1. Terminate the compute instance and cancel any capacity reservation.
2. Delete the portal relationship on both sides.
3. In one CodeBuild run, up to three rounds, two minutes apart, while something
   removable is left:
   - `terraform destroy` of the PCS stack (if it holds resources), the cluster, and the
     network;
   - between the cluster and network: delete the Qumulo provider's
     `/qumulo/<deployment>*` log groups, terminate instances in the spoke VPC that carry
     this hub's tag, and delete any non-default security groups left in the spoke VPC
     (it exists only for this spoke);
   - `spoke/cleanup.py sweep`: finds anything still tagged for the spoke (or named for
     it, where tags aren't possible), removes it, and checks again.

   A failed `terraform destroy` doesn't stop the run: the sweep and the next round deal
   with what's left.
4. The build writes `cleanup-report.json` next to the spoke's state. The workflow reads
   it and succeeds only if the final check was clean.
5. If clean, the Lambda deletes the spoke's files in the state bucket, so refresh-hub
   and placement no longer see a spoke in that region.

**Why the sweep runs in CodeBuild, not the Lambda.** CodeBuild already has the
permissions to create, and so delete, everything a spoke uses. Giving the Lambda delete
rights across EC2, IAM, S3, KMS and Logs would double that surface. The script also runs
by hand (`check` is read-only), so there's one definition of "a spoke's resources".

**Scope.** Removal is by the tags `cnq-path-extender:hub` and
`cnq-path-extender:spoke-region` (including the spoke's tagged rule on the CDF group),
plus the names of the pieces that can't carry tags: the key pair, the secrets, and hub
routes to the spoke's peering connections. Resources that match a spoke's names but carry no tags (possibly
another hub's spoke in the same region) are reported for a person, never removed. S3
buckets are emptied and deleted. KMS keys are scheduled for deletion (7 days, AWS's
minimum). PCS clusters (queues, node groups, then the cluster) and launch templates are
removed before instances, since a node group would replace terminated instances.

## Hub discovery

The operator supplies only:

| Input | Why it can't be derived |
|---|---|
| Hub deployment unique name (the `deployment_unique_name` output of the hub's Terraform) | Identifies the cluster. Several CNQ clusters can share an account, region or VPC. |
| Hub admin secret ARN | The hub's secret is created outside its Terraform, with any name. |

Everything else is found at bootstrap with read-only lookups. The hub region is the
region the control plane is deployed in. The hub's nodes are the running EC2 instances
tagged `Qumulo-Cluster = <deployment unique name>`; from them come the VPC, its CIDR,
the subnets, the route tables, and the node IPs. Bootstrap fails if no instances match
or if they span more than one VPC.

These facts are passed as configuration: Lambda environment variables, CodeBuild
environment variables, and values in the state machine definitions. There's no separate
parameter store. Once, at bootstrap, Terraform invokes the Lambda (`probe_hub`) to sign
in to the hub from inside its VPC and record its cluster UUID and version. Every
deploy-spoke Validate step confirms the hub still reports that UUID.

The Lambda doesn't keep the hub's node IPs in its configuration. It looks them up by
tag on every run, so the control plane follows a hub whose nodes were replaced. Re-run
bootstrap only if the hub moved to different subnets.

## Naming and tagging

Everything is named after its hub, so several control planes can share an account and
it's always clear which hub a resource belongs to.

| What | Name |
|---|---|
| State machines | `deploy-spoke-<hub>`, `destroy-spoke-<hub>`, `refresh-hub-<hub>`, `deploy-local-<hub>`, `destroy-local-<hub>` |
| CodeBuild project | `spoke-build-<hub>` |
| Lambda function, SNS topic | `cnq-path-extender-<hub>` |
| CDF security group | `cdf-<hub>` |
| Spoke state | `<hub>/spokes/<region>/network.tfstate`, `cluster.tfstate`, `pcs.tfstate`, `cleanup-report.json` |
| Local mode state | `<hub>/local/network.tfstate` (the client stack), `pcs.tfstate`, `cleanup-report.json` |
| Code bundle | `<hub>/bundle/spoke.zip` |
| Spoke secrets (spoke region) | `cnq-path-extender/<hub>/<region>/admin`, `cnq-path-extender/<hub>/<region>/ssh-key` |

Tags on everything a spoke or local mode creates:

| Tag | Value |
|---|---|
| `cnq-path-extender:hub` | `<hub>` |
| `cnq-path-extender:spoke-region` | the spoke's region, or `local` for local mode |
| `cnq-path-extender:role` | on some resources: `compute`, `compute-capacity`, `pcs-login`, `pcs-compute` |

Plus any `extra_tags` from bootstrap.

**One spoke per region per hub.** A spoke's state keys, resource names, cluster
deployment name, and peering tags are all keyed by its region. One local deployment per
hub, for the same reason.

## Security model

- **Credentials.** The hub's admin password stays in its own Secrets Manager secret; the
  Lambda reads it to sign in. Each spoke's admin password is generated by Terraform and
  stored in a new secret in the spoke region. The Lambda can read only the hub's secret
  and secrets under `cnq-path-extender/<hub>/`.
- **State files hold secrets.** The network state holds the spoke's generated admin
  password and SSH private key. Keep the state bucket versioned, encrypted, and
  restricted.
- **Network.** The Lambda runs in the hub VPC. It reaches the hub directly and each
  spoke over the VPC peering. Spokes reach the hub on TCP 3713 through the CDF group,
  one rule per spoke CIDR; the hub reaches spokes through the spoke cluster's
  `allow_cidrs`. The client security group allows SSH only from the hub VPC.
- **REST calls don't verify certificates.** CNQ clusters present self-signed
  certificates, so the Lambda's Qumulo REST client doesn't verify them. It only ever
  calls cluster nodes' private addresses, inside the hub VPC or across the peering, never
  over the internet.
- **The CodeBuild role is effectively an administrator.** It has `ec2:*`, `iam:*`,
  `kms:*`, `s3:*`, `secretsmanager:*`, `ssm:*`, `logs:*`, `pcs:*` and more on all
  resources, because the Qumulo provider creates IAM roles, KMS keys, and S3 buckets.
  With `iam:*`, anyone who can change what the project runs can do anything in the
  account. Treat the state bucket (which holds the code bundle) and the ability to start
  builds as admin access.
- **The Lambda role is narrower.** It launches and terminates only instances tagged for
  its hub, passes only `<hub>-*-compute` roles, and reads and deletes only its hub's
  state prefixes.
- **PCS nodes can't read the state bucket.** Nodes get `AmazonS3ReadOnlyAccess` so
  pipelines can read public and private reference data, plus an explicit deny on the
  state bucket, which holds the admin password and SSH key.
- **Instance metadata.** IMDSv2 is required on the compute instance and on PCS nodes.
  PCS nodes allow a hop limit of 2, so containers can reach instance credentials.
- **Terraform download.** CodeBuild downloads the pinned Terraform version from
  HashiCorp at each build and checks it against HashiCorp's published SHA-256 sums. The
  sums file itself isn't signature-checked.
