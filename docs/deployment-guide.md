# Deployment guide

How to set up cnq-path-extender for a hub cluster, launch spoke clusters, and remove them.
Run all commands from the repository root unless a step says otherwise.

There are three phases:

1. **Set up the control plane**: once per hub.
2. **Launch a spoke**: each time you need one.
3. **Remove a spoke**: when you're done with it.

---

## Before you start

You need:

- **An existing hub**: a CNQ cluster in AWS deployed with the Qumulo Terraform provider,
  **running** (not stopped). From its Terraform you'll need:
  - the `deployment_unique_name` output
  - the ARN of the Secrets Manager secret holding its admin password
  - access to run `terraform plan` / `apply` in its folder (one change, in step 1.4)
- **A supported Qumulo Core version on the hub.** Spokes are built at the hub's exact
  version, and portals are set up with the v2 portal REST API. It has only been tested
  on Qumulo Core 7.10.1.1.
- **Access to the Qumulo Terraform provider registry**
  (`qumulo-terraform-registry.s3.us-east-1.amazonaws.com`). CodeBuild downloads the
  provider from it on every spoke build, through the internet.
- **Hub subnets with outbound access through NAT.** The portal Lambda runs in the hub's
  subnets and reaches AWS APIs (Secrets Manager, S3, EC2) through the hub's NAT gateway.
- **An existing S3 bucket** for Terraform state, in the hub's region. It should be
  versioned, encrypted, and restricted: spoke state files contain generated admin
  passwords and SSH keys.
- **On your machine:**
  - Terraform 1.11 or later
  - The AWS CLI (to launch and remove spokes, and to run the cleanup checks)
  - AWS credentials for the hub's account with administrator-level access. Bootstrap
    creates IAM roles, including a CodeBuild role with wildcard IAM permissions (see the
    [security model](architecture.md#security-model)), as well as Lambda, Step
    Functions, CodeBuild, SNS, CloudWatch log groups, EC2 security groups, and S3
    objects.
- **Your organization's required tags, if any.** If your AWS organization blocks
  launching resources without certain tags (for example, through a service control
  policy), put those tags in `extra_tags` (step 1.1). Without them, the spoke cluster's
  EC2 instances can't launch.
- **Address ranges for spokes.** Each spoke gets its own new VPC, and you choose its
  CIDR at launch (see step 2.1). Get ranges from whoever manages your network so they
  don't collide with anything else.
- **Enough vCPU quota in each spoke region.** EC2 limits the On-Demand vCPUs each
  instance family can run per region, and a low quota is a common reason a spoke or compute
  instance can't launch. Check the quotas for the cluster's instance family (and the
  compute instance's family, if you use one) in Service Quotas before you launch, and request an increase
  if needed. Validate also checks the cluster's quota and stops early if it's too low.
- **A copy of this code.** Updates are not pulled automatically; see "Updating" below.

---

## Phase 1: Set up the control plane (once per hub)

### Step 1.1: Fill in the settings

Copy `bootstrap/terraform.tfvars.example` to `bootstrap/terraform.tfvars` and fill in.
`terraform.tfvars` is not committed to git, so account-specific values stay local.

| Variable | Example | What it's for |
|---|---|---|
| `hub_region` | `us-west-2` | Where the hub lives. The control plane is deployed here. |
| `hub_deployment_unique_name` | `hubprod-a1b2c3` | Which CNQ cluster is the hub. Selects exactly one cluster even if several share the account. |
| `hub_admin_secret_arn` | `arn:aws:secretsmanager:us-west-2:…` | Hub admin credentials, used to authorize portals on the hub. |
| `state_bucket` | `my-tf-state-bucket` | Existing S3 bucket for Terraform state and the code bundle. |
| `notification_email` | `you@example.com` | Where success and failure emails go. |
| `default_instance_type` | `i7i.8xlarge` | Spoke instance type when a launch doesn't specify one. Default `i7i.8xlarge`. |
| `default_node_count` | `3` | Spoke node count when a launch doesn't specify one. Default `3`. |
| `spoke_capacity_tb` | `100` | Soft capacity limit for every spoke. Default `100`. |
| `spoke_product_type` | `HOT` | `HOT` or `COLD` for every spoke. Default `HOT`. |
| `portal_type` | `PORTAL_READ_WRITE` | Spoke access: `PORTAL_READ_WRITE` or `PORTAL_READ_ONLY`. Default read-write. |
| `terraform_version` | `1.16.5` | Terraform version CodeBuild uses. Has a default. |
| `extra_tags` | `{ "owner" = "you@example.com" }` | Optional. Added to every resource the control plane and spokes create, including the cluster's EC2 instances. Use it for tags your AWS organization requires. |

### Step 1.2: Deploy the control plane

From the `bootstrap/` folder:

```bash
cd bootstrap
terraform init \
  -backend-config=bucket=<state_bucket> \
  -backend-config=region=<hub_region> \
  -backend-config=key=<hub_deployment_unique_name>/bootstrap/terraform.tfstate
terraform plan
terraform apply
```

What happens:

1. **Discovery (read-only).** Finds the hub's running EC2 instances by the tag
   `Qumulo-Cluster = <hub_deployment_unique_name>`, and from them the hub's VPC, CIDR,
   subnets, route tables, and node IPs. Stops with an error if no instances match or
   they span more than one VPC.
2. **Uploads** a zip of `spoke/` to `s3://<state_bucket>/<hub>/bundle/spoke.zip`.
   CodeBuild runs this copy.
3. **Creates**, all named after the hub:
   - CDF security group `cdf-<hub>` in the hub VPC (no rules yet)
   - Portal Lambda `cnq-path-extender-<hub>`, in the hub's subnets
   - CodeBuild project `spoke-build-<hub>`
   - State machines `deploy-spoke-<hub>`, `destroy-spoke-<hub>`, `refresh-hub-<hub>`,
     `deploy-local-<hub>` and `destroy-local-<hub>`
   - SNS topic `cnq-path-extender-<hub>` with your email subscribed
   - IAM roles and CloudWatch log groups for all of the above
4. **Probes the hub.** Invokes the Lambda once to sign in to the hub from inside its VPC
   and record its cluster UUID and version. If the hub doesn't answer, or the admin
   secret is wrong, `apply` fails here with the reason.
5. **Outputs:**
   - `cdf_security_group_id`: needed in step 1.4
   - `deploy_spoke_state_machine_arn`, `destroy_spoke_state_machine_arn`,
     `refresh_hub_state_machine_arn`
   - `deploy_local_state_machine_arn`, `destroy_local_state_machine_arn`: for
     [local mode](local-mode.md)
   - `hub`: everything discovered (UUID, version, VPC, IPs, subnets, route tables).
     Worth a look.
   - `launch_example`: a deploy-spoke launch command to fill in

**If the hub's nodes are replaced later** (for example, by changing their instance
type), they get new IPs. The control plane looks up the hub's nodes each time it runs, so
it follows them on its own, but existing spokes' portals keep the old addresses. Run
`refresh-hub-<hub>` to point them at the new ones (see "When the hub's nodes change"
below). Re-run `terraform apply` here only if the hub moved to different subnets.

### Step 1.3: Confirm the email subscription

AWS sends a confirmation email to `notification_email`. Click the link, or notifications
won't arrive.

### Step 1.4: Attach the CDF security group to the hub

In the **hub's** Terraform folder, **add** the security group ID from step 1.2 to
`additional_security_group_ids`, keeping any groups already listed there:

```hcl
additional_security_group_ids = ["<groups already attached>", "<cdf_security_group_id>"]
```

Replacing the list instead would detach the hub's existing groups and cut off whatever
access they provide.

Run `terraform plan` and confirm it shows **`~ update in-place`** (no replacement). Then
run `terraform apply`.

This lets spokes reach the hub on TCP 3713 (portal traffic). The hub's Terraform only
attaches the group; the per-spoke rules inside it are managed by this tool and survive
future hub applies. Traffic the other way (hub to spoke) is allowed by each spoke's own
security group, which the tool sets up.

**Setup is complete.** You don't repeat it for this hub.

---

## Phase 2: Launch a spoke

### Step 2.1: Choose the inputs

| Input | Required | Format | Notes |
|---|---|---|---|
| `region` | yes, unless `placement` is given | AWS region name | Where the spoke goes. Must be a different region from the hub, and enabled in your account. **One spoke per region per hub:** the spoke's state, names and peering are keyed by region. |
| `placement` | instead of `region` | Object: `{}`, or `{"regions": [...]}` | Let the tool choose the region (see "Optional: let the tool choose the region" below). |
| `path` | yes | Absolute path, e.g. `/projects/foo` | A directory that exists on the hub. The spoke gets the same path. |
| `vpc_cidr` | yes | IPv4 CIDR block, prefix length `/16` to `/24` | The address range for the spoke's new VPC. It must be a range reserved for this spoke and must not overlap the hub's VPC, other spokes, or any network that needs to reach the spoke or that the spoke's traffic must not be confused with (on-premises networks, VPN ranges, other VPCs). Validate rejects overlaps with the hub VPC and with any VPC peered with it; it can't see the rest of your network, so choose carefully. |
| `instance_type` | no | EC2 instance type | Families: m6idn, m6i, m7i, i3en, i4i, i7i, i7ie. Defaults to `default_instance_type`. |
| `node_count` | no | Whole number | 1, or 3 to 24. Defaults to `default_node_count`. |
| `availability_zone` | no | AZ name, e.g. `us-east-2b` | Where the spoke goes, within `region`. Leave it out to let the tool choose: the first standard zone that offers `instance_type`. |
| `client_resources` | no | `true` or `false` | `true` adds a security group and a Session Manager instance role to the spoke VPC, for instances you launch there yourself (see "Your own clients" below). Default `false`; a `compute` launch turns it on. Once on, it stays on for that spoke. |
| `compute` | no | Object, see below | Also launch a compute instance (any instance type) in the spoke, with the portal path mounted, optionally set up for an application. |
| `pcs` | no | Object, see below; `{}` for the cluster alone | Also build an AWS PCS (Slurm) cluster in the spoke, every node mounting it, optionally with a pipeline set up. Needs `region`. |

Any other top-level input is rejected, as are unknown settings inside `placement`,
`compute` and `pcs`, so a misspelled name fails at Validate instead of being ignored.

### Optional: let the tool choose the region

Give `placement` instead of `region`, and the tool picks the region:

```json
"placement": { "regions": ["ap-northeast-2", "ap-northeast-1"] }
```

- **Which regions it tries.** The ones in `regions`, in that order. With `"placement": {}`,
  every enabled region except the hub's, nearest to the hub first: Validate times a
  connection from the hub's VPC to each region's EC2 endpoint (best of three) and sorts
  by it, so the region closest to the data wins. Regions that already have a spoke of this
  hub are left out. The order is in the email (`regions_search_order`).
- **Without a compute instance,** it takes the first of those regions that offers the
  cluster's instance type and has On-Demand vCPU quota for it, after what's already
  running there.
- **With a compute instance,** it takes the first region and zone where capacity for the
  compute instance can be reserved (see "Finding capacity" below). That's usually the
  harder thing to find.
- **Skipped regions,** and why, are listed in the email (`regions_skipped`).
- **Resuming.** A re-run with the same `vpc_cidr` finds the spoke the first run created
  and resumes it in its region; it doesn't search again.

`availability_zone` and `compute.ami_id` need a fixed `region`: zone names and AMI IDs
belong to one region.

### Optional: a compute instance

Add a `compute` object to the launch input to also get an instance in the spoke's VPC,
with the spoke's portal directory mounted. It can be any instance type: a GPU instance for
Parabricks is one example, a large-memory instance for testing another.

Two settings decide what goes on it, and they're independent:

- **The image** (`ami_id`, optional): without it, each instance type gets its default
  AMI (below). With it, your own image is used instead. Either way, the tool adds the NFS
  client, scratch space, and the mount.
- **An application** (`application`, optional): set up for you at first boot, on the
  default AMI or your own, including any OS settings it needs. On a custom AMI, the image
  must have what the application needs (for Parabricks, Docker and the NVIDIA container
  toolkit). **Parabricks** (`parabricks`) is the only application so far; others can be
  added to [`lambdas/portal/apps/`](../lambdas/portal/apps/) (see its README).

```json
"compute": {
  "instance_types": ["g5.48xlarge", "g6e.48xlarge"],
  "application": "parabricks",
  "application_options": { "version": "4.8.0-1" }
}
```

| Setting | Default | What it does |
|---|---|---|
| `instance_types` | (required) | Instance types to try, in order of preference. Each must be a real EC2 instance type. |
| `ami_id` | Amazon Linux 2023 (Deep Learning AMI for GPU types) | A custom AMI. It must exist in the spoke's region (so it needs `region`), and be a Linux image with systemd and `dnf` or `apt-get`, for the mount. |
| `application` | none | An application to set up, on the default or custom AMI: currently `parabricks`, which needs GPU types. |
| `application_options` | none | Settings for the application, documented at the top of its file. Names: a letter, then letters, digits and `_`. Values: letters, digits and `. _ : / @ + = , -`. |
| `retry_minutes` | `5` | How long to wait between rounds when nothing has capacity. 2 to 60. |
| `give_up_after_hours` | `24` | Stop looking after this long: more than 0, at most 168 (one week). A new spoke is then not built, and the email lists what was tried. |
| `root_volume_gb` | `200` | Root volume size, 8 to 16384. |

Validate also checks:

- **Attempts.** `give_up_after_hours × 60 / retry_minutes` must be at most 1,500 (a Step
  Functions history limit). For a week, use `retry_minutes` of 7 or more.
- **Offered types.** For a new spoke, a zone is a candidate only if it offers the
  cluster's type and at least one of `instance_types` (see "Candidate zones" below). On
  an existing spoke, the types are tried in its zone.
- **GPUs.** An application marked `requires: gpu` (Parabricks) refuses types without
  GPUs.

The default AMI follows each instance type: Amazon Linux 2023 for its architecture
(arm64 if the type supports it, else x86_64), or for types with GPUs, the AWS Deep
Learning Base OSS NVIDIA Driver GPU AMI for that architecture, which adds NVIDIA drivers,
Docker, and the NVIDIA container toolkit. You can mix x86_64 and arm64 types in
`instance_types` with the default AMIs. A custom `ami_id` has one architecture, so list
only types that match it. Validate doesn't check an application against the
architecture, so make sure the application supports the types you list.

How it works:

- **Candidate zones.** For a new spoke, Validate lists the zones the search may use:
  in `region` (and `availability_zone`, if given), or in the regions `placement` tries
  (above). A zone qualifies if it offers the cluster's instance type
  and at least one of the compute types, and its region's On-Demand vCPU quotas are large
  enough for the cluster (plus a temporary 4-vCPU provisioner) and for that type. Regions
  left out, and why (for GPU types, most often a quota of 0), are listed in the email.
  This search checks quota limits only, not what's already running against them.
- **Finding capacity.** Before anything is built, the workflow requests a one-instance
  On-Demand Capacity Reservation in each candidate zone in turn: regions in search
  order, then zones, then instance types in your order. A request either fails at no
  cost or succeeds, which means the capacity exists and is now held. If none succeeds,
  it waits `retry_minutes` and tries again, until `give_up_after_hours`.
- **Then the spoke.** The zone that succeeded decides the spoke's region and zone. The
  network is built there, the compute instance launches into the reservation (in the
  same zone as the cluster, so NFS traffic stays within it), and the reservation is
  cancelled; the running instance isn't affected. The cluster and portal follow as usual.
- **Cost of the reservation.** It's billed like a running instance from the moment it's
  found: about 10 minutes while the network builds, then the instance itself. If the
  deploy fails, it's cancelled; as a backstop it expires after 3 hours on its own.
- **Mounting.** The instance can come up before the cluster does. Once the portal is
  active, the workflow tags the instance with the spoke's node IPs, and the instance
  mounts the spoke at `/mnt/qumulo`: the portal directory is at `/mnt/qumulo<path>`,
  linked as `~/data`. NFSv3 with `nconnect=16` and 1 MiB reads and writes; the mount is in
  `/etc/fstab`.
- **Scratch.** Fast local space for temporary files, at `$PA_SCRATCH`: the instance's
  NVMe storage when the type has some (striped across its disks), else the root volume.
- **Parabricks.** Set up at first boot: the container is pulled, a `pbrun` command runs
  it with the spoke and scratch mounted, as your user, and Linux's writeback is
  shortened (data sent after 1 second or 512 MB, in
  `/etc/sysctl.d/90-cnq-path-extender-writeback.conf`), so a large-memory instance
  writes `fq2bam`'s BAM to the spoke steadily instead of in large bursts. Without an
  application, Linux's write-cache defaults are left alone.
- **Access.** Session Manager (the instance has the SSM role), or SSH as the image's
  login user (`ec2-user` on Amazon Linux) from the hub VPC with the spoke's key (Secrets
  Manager: `cnq-path-extender/<hub>/<region>/ssh-key`). Progress:
  `cat /var/lib/cnq-path-extender/status`; full log: `/var/log/cnq-path-extender-setup.log`.
  The instance is ready when the status ends with "setup finished … ready to use": that
  line comes only once both the application's setup and the spoke mount are done.

A large compute instance can cost far more than the spoke (a g5.48xlarge is about
$16/hour), and it runs until you remove the spoke (or terminate it yourself). If the cluster build fails,
an instance already found keeps running; resume the launch or run destroy-spoke.

The tag keys in `extra_tags` must use only letters, digits, and `+ - = . , _ : @`: the
instance reads its own tags through instance metadata, which restricts tag keys.

To add an application, see [`lambdas/portal/apps/README.md`](../lambdas/portal/apps/README.md).

### Optional: a PCS cluster (Slurm) with a pipeline

Add a `pcs` object to get an AWS Parallel Computing Service cluster (managed Slurm) in
the spoke's subnet: one login node, compute nodes that start when jobs are queued and
stop when idle, and one queue, `compute`. Every node mounts the spoke. With `pipeline`,
the login node also sets up a Nextflow pipeline and a command to run it.

```json
"pcs": {
  "pipeline": "xoos",
  "compute_instance_type": "c6i.4xlarge",
  "max_nodes": 4
}
```

| Setting | Default | What it does |
|---|---|---|
| `pipeline` | none | `xoos` (Roche SBX: the xoosnf pipeline, launcher, and public smoke data) or `sarek` (nf-core/sarek). Without it, the cluster alone, with Nextflow and Apptainer ready. |
| `pipeline_options` | none | Settings for the pipeline, documented at the top of its file in [`spoke/pcs/pipelines/`](../spoke/pcs/pipelines/) (see its [README](../spoke/pcs/pipelines/README.md)). Sarek: `version` (3.7.1), `genome` (GATK.GRCh38), `tools` (haplotypecaller). Xoos: `xoosnf_ref`, `xoos_ref`, `dataset` (1.1.0). Same name and value rules as `application_options`. |
| `compute_instance_type` | `c6i.4xlarge` | Compute node type, x86_64 only. Slurm sees its physical cores only: a c6i.4xlarge is 8 CPUs, not 16. |
| `max_nodes` | `4` | Most compute nodes at once, 1 to 64. |
| `idle_minutes` | `20` | Idle compute nodes stop after this, 1 to 1440. Keep it longer than a pipeline's longest single task, or the other nodes stop and must boot again (about 5 minutes) mid-run. |
| `login_instance_type` | `c6i.xlarge` | Login node type, x86_64 only. It runs all the time. |
| `root_volume_gb` | `100` | Root volume per node, 30 to 16384. |

`pcs` needs `region` (not `placement`). Validate checks that the region offers PCS, and
that both instance types exist, are x86_64 (the node setup installs x86_64 packages, and
the PCS sample AMI is x86_64), and are offered in the region. The cluster is built last,
after the portal is up (about 15–20 minutes more), so the nodes can mount the portal
path. The spoke's other inputs work as before; a spoke without `pcs` gets one added by
launching again with the same inputs plus `pcs`.

The nodes run AWS's PCS sample AMI for Slurm 25.11. AWS provides it for testing and
doesn't support it for production use.

On every node:

- **The spoke** at `/mnt/qumulo` (NFSv3, `nconnect=16`, 1 MiB reads and writes, as on the
  compute instance, plus `lookupcache=positive` so files one node creates show on the others
  at once: Nextflow watches for each task's exit file). Nodes take the spoke's nodes in
  turn, so the load spreads evenly across the cluster. The portal directory is
  `$PA_DATA` (`/mnt/qumulo<path>`).
- **Shared space** at `$PA_SHARED` (`/mnt/qumulo/pcs`, on the spoke but outside the
  portal path, so it isn't copied to the hub): Nextflow, the container cache, temp
  space, work directories, references, and run directories.
- Java 17, Python 3.12, Apptainer 1.4.1, and the Slurm commands on `PATH`.

`$PA_SHARED/conf/pcs.config`, written by the login node, sets for any Nextflow pipeline:

- **Slurm** as the executor, on the `compute` queue.
- **Limits of one compute node** (`resourceLimits`): its physical cores, 90% of its
  memory, and 72 hours per task. Nextflow cuts a larger request down to these, so no
  task waits forever for a node bigger than the cluster has.
- **Queue:** at most 200 tasks queued in Slurm at once, submitted at most 10 per second.
- **Apptainer** with `--userns`, images cached in `$PA_SHARED/apptainer-cache`, and a
  2-hour pull timeout.
- **Trace:** a raw per-task trace with timings and I/O, which `bench-summary` and
  `bench-steps` read.

Using it:

1. **Connect** to the login node with Session Manager. Find it by its tag:

   ```bash
   aws ec2 describe-instances --region <spoke region> --filters "Name=tag:cnq-path-extender:role,Values=pcs-login" "Name=tag:cnq-path-extender:hub,Values=<hub_deployment_unique_name>" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text
   ```

   ```bash
   aws ssm start-session --region <spoke region> --target <instance ID from the command above>
   ```

   Then `sudo -iu ec2-user`: jobs run as `ec2-user`.
2. **Wait for setup:** `cat /var/lib/cnq-path-extender/status` ends with "setup finished
   (pipeline: …); ready to use" once Nextflow and the pipeline are installed (a few
   minutes after the node starts).
3. **Run.** Nextflow itself runs as a Slurm job on a compute node, so you can log out.
   Watch with `squeue`.
   - **Xoos:** `run-xoos-smoke` submits the three smoke tests (BAM, demultiplexed FASTQ,
     basecall FASTQ). Each writes VCFs to `$PA_DATA/results/xoos-smoke/<time>/<test>/output`.
     Per-task CPUs, memory and HaplotypeCaller options are set in the `pcs` profile
     (see [pipelines/README.md](../spoke/pcs/pipelines/README.md)).
   - **Sarek:** `sarek-samplesheet <FASTQ directory> > samples.csv` writes a samplesheet
     for paired FASTQs (check it), then `run-sarek samples.csv` runs Sarek on them.
     Results go to `$PA_DATA/results/sarek/<time>`; add `-- <more arguments>` for
     anything else Sarek takes (e.g. `-- --tools deepvariant`).
     - **Right-sizing.** Sarek's default requests ask for most of a c6i.4xlarge even for
       light steps, so tasks would run one per node. `run-sarek` adds
       `$PA_SHARED/conf/sarek-pcs.config`, which overrides the per-process CPU and
       memory requests of the main germline steps (BWA-MEM, MarkDuplicates, BQSR,
       HaplotypeCaller, and others) with smaller ones, so several tasks share a node.
       Retries still double the memory.
     - **nf-core's own settings.** To run one of nf-core's test profiles as nf-core does
       (its tools, settings, and Sarek's own resource requests, without
       `sarek-pcs.config`), set `SAREK_PROFILE`, e.g.
       `SAREK_PROFILE=test_full_germline run-sarek samples.csv`. The samplesheet can then
       be a URL. Requests larger than one node are capped to it by `pcs.config`; to run
       them uncapped, pick a `compute_instance_type` at least as large as the biggest
       request, and an `idle_minutes` longer than the longest task.
     - **References.** By default Sarek reads its iGenomes references from AWS's public
       S3 bucket. Copy them once to `$PA_SHARED/references/igenomes` (the same layout
       as the bucket) and `run-sarek` uses that copy instead, unless you pass
       `--igenomes_base`.
   - **Timings:** `bench-summary <results directory>` (for Xoos, `<test>/output`) prints
     a run's pipeline time, failed or retried tasks, node-hours and I/O, from its trace.
     Billed node-hours count a boot and an idle tail for every time a node powers off
     mid-run and starts again. `bench-steps <results directory> ...` prints each step's
     tasks, task-hours, CPU-hours and longest task, for one run or several side by side.
   - **Anything else:** `nextflow run <pipeline> -profile apptainer -c $PA_SHARED/conf/pcs.config`
     sets Slurm, Apptainer, and per-task timings for any Nextflow pipeline.

   Results under `$PA_DATA` reach the hub through the portal. Each run's trace
   (`pipeline_info/` in its results) records every task's time and I/O.

Logs: `/var/log/cnq-path-extender-setup.log` on each node. A compute node that's running
jobs has finished its setup: it joins Slurm only after.

Costs: the PCS controller and the login node run until the spoke is removed; compute
nodes cost only while they run. See "Costs at a glance" below.

To run the same modules next to the hub instead, for comparison, see
[local mode](local-mode.md).

### Step 2.2: Start it

**Console:** Step Functions (in the hub's region) → `deploy-spoke-<hub>` →
**Start execution**, and paste:

```json
{
  "region": "<spoke region>",
  "path": "<path on the hub>",
  "vpc_cidr": "<spoke VPC CIDR>",
  "instance_type": "i7i.8xlarge",
  "node_count": 3
}
```

`instance_type` and `node_count` can be left out to use the defaults.

**CLI:** the `launch_example` output of bootstrap is this command with every input
listed, required ones marked `REQUIRED` and optional ones `OPTIONAL`. Fill in what you
want; any `<OPTIONAL...>` placeholder left as is means the default. A spoke alone:

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <deploy_spoke_state_machine_arn> --input '{"region": "<spoke region>", "path": "<path on the hub>", "vpc_cidr": "<spoke VPC CIDR>", "instance_type": "i7i.8xlarge", "node_count": 3}'
```

With a compute instance, here a GPU instance for Parabricks (see "Optional: a compute instance"):

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <deploy_spoke_state_machine_arn> --input '{"region": "<spoke region>", "path": "<path on the hub>", "vpc_cidr": "<spoke VPC CIDR>", "compute": {"instance_types": ["g5.48xlarge", "g6e.48xlarge"], "application": "parabricks", "application_options": {"version": "4.8.0-1"}}}'
```

The command returns immediately. Follow progress in the Step Functions console, or wait
for the email.

### Step 2.3: What the workflow does

| # | Step | What happens | Runs on |
|---|---|---|---|
| 1 | Validate | Confirms the hub is still the same cluster (UUID). Checks the region, sizing, that `path` is a directory on the hub, that `vpc_cidr` doesn't overlap the hub VPC or VPCs peered with it, and the `compute` settings. For a new spoke, checks the region (and zone, if given) offers `instance_type` and that its On-Demand vCPU quota has room for the nodes plus the 4-vCPU provisioner, after instances already running: a spoke that can't be built fails here in seconds instead of in the build. If this region already has a spoke from an earlier launch with the same inputs, continues it (see "If a launch fails partway"); different inputs are refused. Reads the hub's version (e.g. `7.10.1.1`). | Lambda |
| 1a | Find capacity | Only for a new spoke with `compute`: requests capacity reservations for the compute instance across the candidate zones every `retry_minutes` until one succeeds. That zone becomes the spoke's region and zone. | Lambda + wait loop |
| 2 | Build network | `terraform apply` of `spoke/network/`: VPC, private and public subnets, NAT gateway, S3 gateway endpoint, peering (requested from the spoke, accepted in the hub region), routes both ways, the 3713 rule on the CDF group, a generated admin password and SSH key in Secrets Manager, and, with `client_resources` or `compute`, a client security group and instance role. | CodeBuild |
| 2a | Build cluster | `terraform apply` of `spoke/cluster/`: the CNQ cluster, pinned to the hub's version. Refuses to continue if an existing spoke cluster's instances are stopped. Steps 3–5 follow it. | CodeBuild |
| 2b | Launch compute | Only with `compute`, alongside 2a–5: launches the compute instance into the reservation from 1a and cancels the reservation. (Resuming an existing spoke, there's no reservation: it retries until there's capacity in the spoke's zone.) | Lambda + wait loop |
| 3 | Wait healthy | Polls the spoke's API until every node is active (up to 90 minutes). | Lambda + wait loop |
| 4 | Portal | Re-checks hub and spoke versions match. Creates a spoke portal for `path` and proposes it to the hub, then accepts it and authorizes the path on the hub. | Lambda |
| 5 | Verify | The spoke portal reports ACCEPTED and ACTIVE with its root authorized. If it's accepted and authorized but still not ACTIVE after about 2 minutes (DEGRADED), the deploy carries on with a warning; if it isn't even accepted after 10 minutes, the deploy fails; see "Portal status" below. Then a node-by-node portal ping in both directions, for the summary. | Lambda |
| 6 | Mount | Only if a compute instance was launched: tags it with the spoke's node IPs so it mounts the spoke. | Lambda |
| 6a | Build PCS | Only with `pcs`: `terraform apply` of `spoke/pcs/`: the PCS cluster, login and compute node groups, the queue, their launch templates, security group, and node role. The login node then sets up Nextflow and the pipeline on its own. | CodeBuild |
| ✉ | Notify | Success email (spoke address, node IPs, admin secret ARN, and the compute instance or why there isn't one) or failure email (which step failed and why). On failure, any capacity reservation still held is cancelled; nothing else is torn down. | SNS |

### Portal status

See also [known issues](known-issues.md).

A portal relationship has a state (`PENDING`, `ACCEPTED`, `DELETING`) and a status:
`ACTIVE`, or `DEGRADED` when some of the connections between the two clusters are
missing. A DEGRADED portal still moves data over the connections it has.

The most likely cause here isn't the new spoke at all: **any portal relationship on the
hub that isn't ACTIVE makes the hub's other relationships report DEGRADED too.** For
example, the hub is a spoke of another cluster that's been stopped, or a hub relationship
whose spoke was removed without deleting the portal. Starting the stopped peer turns them
all ACTIVE again.

So the deploy:

- **Warns before it starts.** Validate lists the hub's relationships that aren't ACTIVE
  in the summary (`hub_portal_warnings`). The launch goes ahead.
- **Doesn't fail a working spoke.** If the new portal is accepted and authorized but not
  ACTIVE after about 2 minutes, the deploy completes, mounts the compute instance, and says so in
  `portal_warning`.
- **Reports connectivity.** `portal_ping` in the summary shows each node on one side
  against each host on the other, in both directions.

To fix a DEGRADED portal:

1. Run `qq portal_list` on the hub. If any other relationship isn't Active or Healthy,
   bring its peer back, or delete the relationship from the correct side.
2. Check `portal_ping`, or run `qq portal_ping` on both clusters. Every node must reach
   every configured address on TCP 3713 in both directions.
3. Check that both host lists are the current node IPs: `qq portal_get_hub` and
   `qq portal_get_spoke`.

**Order matters when you retire a cluster that has portals.** Delete its portal
relationships first, while both clusters are running, then stop or remove it. A delete
without `--force` syncs pending spoke writes to the hub first. `--force` discards them,
so keep it for a peer that's gone for good. destroy-spoke deletes its own spoke's
relationship before removing anything.

### When the hub's nodes change

Replacing the hub's nodes (for example, changing their instance type in the hub's
Terraform) gives them new IPs. Spoke portals keep trying the old addresses, so they go
Disconnected, and anything mounted through them hangs. Once the hub is back up, run:

```bash
aws stepfunctions start-execution --region <hub_region> --state-machine-arn <refresh_hub_state_machine_arn> --input '{}'
```

For each spoke of this hub (or just one, with `{"region": "<spoke region>"}`), it finds
the spoke's portal to this hub by the hub's cluster UUID and, if its hub addresses are
out of date, sets them to the hub's current nodes. The email lists what changed and each
portal's state right after. A spoke it can't reach is reported and the rest carry on.

Clients that mount the hub directly (not through a spoke) need their mounts pointed at a
new hub address too; this workflow doesn't touch them.

### If a launch fails partway

Nothing is torn down. Fix the cause, then start `deploy-spoke` again with the **same
inputs**: it resumes. Terraform reports no changes for what already exists, an existing
portal is reused, and the workflow continues from there. Different inputs for a region
that already has a spoke are refused; run `destroy-spoke` first if you want to start over.

### Don't abort a running deploy

Stopping a deploy-spoke execution also stops its CodeBuild run, which kills Terraform
mid-apply. Two things are left behind:

- **A state lock** (`<hub>/spokes/<region>/<stack>.tfstate.tflock` in the state bucket).
  Later runs remove a lock automatically once it's older than the build timeout (about
  3 hours); to retry sooner, delete it yourself:
  `aws s3 rm s3://<state_bucket>/<hub>/spokes/<region>/cluster.tfstate.tflock`
- **Cluster resources no state tracks**, if the cluster stack was running: the Qumulo
  provider's provisioner instance (an m5.xlarge named `spk<region>-<suffix>-provisioner`,
  left running and billing), security groups, IAM roles and instance profiles, and log
  group. destroy-spoke removes all of them: they carry the spoke's tags.

If a deploy is taking too long, let it fail on its own, or run destroy-spoke after it
finishes.

### Your own clients

To run your own instances against the spoke (test clients, for example), launch with
`"client_resources": true`. The network stack's outputs then include a client security
group (all outbound, SSH from the hub VPC) and an instance profile for Session Manager:
`client_security_group_id` and `client_instance_profile_name`. Launch into the spoke's
private subnet (`private_subnet_id`) with those, and mount any spoke node's IP, as in
"Optional: a compute instance".

Tag your instances `cnq-path-extender:hub = <hub>` and `cnq-path-extender:spoke-region = <region>`
so destroy-spoke removes them with the spoke.

### Where to find things afterwards

- **Spoke admin password:** Secrets Manager (spoke region), `cnq-path-extender/<hub>/<region>/admin`
- **Node SSH key:** Secrets Manager (spoke region), `cnq-path-extender/<hub>/<region>/ssh-key`
- **Spoke state:** `s3://<state_bucket>/<hub>/spokes/<region>/network.tfstate`,
  `cluster.tfstate`, and `pcs.tfstate` (with `pcs`)
- **Build logs:** the CodeBuild run linked from the execution

---

## Phase 3: Remove a spoke

**Before you start:**

- **The spoke's instances must be running.** If you stopped them (e.g. to save money),
  start them and wait until they're running. destroy-spoke checks and refuses otherwise:
  the Qumulo provider treats a stopped cluster as gone, so Terraform would lose track of
  it instead of destroying it.
- **Remove instances you launched in the spoke VPC yourself,** unless you tagged them
  `cnq-path-extender:hub = <hub>` and `cnq-path-extender:spoke-region = <region>`: destroy-spoke
  terminates tagged instances, but leaves untagged ones alone, and their network
  interfaces stop the spoke's VPC from being deleted. It then reports the VPC as left over.
- **Make sure nothing on the spoke needs keeping.** Spokes are deployed with deletion
  protection off so removal always works.

Start `destroy-spoke-<hub>` (in the hub's region) with:

```json
{ "region": "<spoke region>" }
```

If the spoke is broken and can't be reached, add `"force": true` to skip the spoke side
of portal removal and force-delete the hub side:

```json
{ "region": "<spoke region>", "force": true }
```

What it does:

1. **Checks** that the spoke's instances are running, then **terminates the compute
   instance**, if the launch created one.
2. **Removes the portal** relationship on both the spoke and the hub. If the spoke
   doesn't answer, it skips the spoke side and force-deletes the hub side.
3. **Destroys** the PCS cluster (if the launch had `pcs`), the cluster, then the network:
   VPC, peering, routes, the spoke's 3713 rule on the hub, secrets, key pair, and client
   resources. Data under `/mnt/qumulo/pcs` goes with the spoke; results under the portal
   path are on the hub too.
4. **Sweeps and checks.** [`spoke/cleanup.py`](../spoke/cleanup.py) looks for everything a
   spoke can create, including what Terraform lost track of (a launch that failed or was
   aborted partway), and removes it: PCS clusters, instances, launch templates, capacity reservations, VPCs and their
   parts, security groups, Elastic IPs, volumes, placement groups, S3 buckets (with their
   contents), log groups, IAM roles and instance profiles, secrets, the key pair, and on
   the hub, the peering connection, routes, and 3713 rule. KMS keys are scheduled for
   deletion (AWS's minimum is 7 days). Then it checks again. If anything's left that it
   could remove, it waits 2 minutes and repeats destroy and sweep, up to 3 times in all.
5. **Notifies.** Success means the final check found nothing. Otherwise the email,
   subject "LEFTOVERS need removing", lists each resource that's left, and the execution
   fails with `LeftoversRemain`. Items marked `[needs a person]` match the spoke by name
   but not by tag, so they may belong to another hub's spoke in the same region; the
   sweep never removes those.

The sweep removes only resources tagged `cnq-path-extender:hub = <hub>` and
`cnq-path-extender:spoke-region = <region>`, plus the few that can't carry tags and are named
for this spoke: its key pair and secrets, and hub routes to its peering connections.

### Check by hand

The same check, read-only, from anywhere with Python 3, boto3, and credentials for the
account:

```bash
python3 spoke/cleanup.py check --hub <hub_deployment_unique_name> --hub-region <hub_region> --region <spoke_region> --vpc-cidr <spoke_vpc_cidr>
```

It lists anything left and exits non-zero if there is. `--vpc-cidr` is optional; it finds
hub routes left pointing at the spoke after its peering connection is gone. The
destroy build leaves `cleanup-report.json` next to the spoke's state in the state bucket.
When its check is clean, the workflow then deletes the spoke's files there (the emptied
state files and the report; the email lists them under `state_files`), so later runs
don't see a spoke in that region. In a versioned bucket the old versions remain. When
the check isn't clean, the files stay, so the report can be read.

---

## Removing the control plane

Only if you're retiring cnq-path-extender for this hub. Remove all spokes first (Phase 3).

1. In the **hub's** Terraform, remove the CDF security group ID from
   `additional_security_group_ids`, keeping the other groups. Run `plan` (expect
   `~ update in-place`), then `apply`.
2. In `bootstrap/`, run `terraform destroy`.

The order matters: AWS won't delete a security group that's still attached to the hub's
network interfaces, so step 2 fails if step 1 is skipped.

AWS keeps a VPC Lambda's network interfaces for up to ~45 minutes after the function is
deleted. To avoid waiting on that, Terraform first moves the Lambda onto the hub VPC's
`default` security group, so the Lambda's own group deletes at once; AWS then removes
the leftover interfaces in the background. (If it's ever slow anyway, Terraform waits up
to 45 minutes rather than failing.) This takes effect only if the control plane was last
applied with this code, so run `terraform apply` once before `terraform destroy` after
updating.

What remains afterwards, and why:

- **Files under `s3://<state_bucket>/<hub>/`**: the bucket is yours. Terraform empties the
  state files but doesn't delete them. Remove them with
  `aws s3 rm s3://<state_bucket>/<hub>/ --recursive`; in a versioned bucket, old
  versions remain until deleted separately.
- **EventBridge rule `StepFunctionsGetEventForCodeBuildStartBuildRule`**: created by AWS
  once per account and region and shared by every Step Functions workflow that waits on
  CodeBuild. Leave it; it costs nothing.
- **KMS keys from spokes**: already scheduled for deletion (AWS enforces a 7–30 day wait).

Confirm with the read-only check:

```bash
scripts/check-control-plane-cleanup.sh <hub_deployment_unique_name> <hub_region> <state_bucket>
```

It makes only describe and list calls, and reports `ok` or `FOUND` for each of:

- anything in the hub region tagged `cnq-path-extender:hub = <hub>`
- the five state machines, the CodeBuild project `spoke-build-<hub>`, the Lambda
  function and SNS topic `cnq-path-extender-<hub>`, and the IAM roles
  `cnq-path-extender-*-<hub>`
- the security groups `cdf-<hub>` and `cnq-path-extender-lambda-<hub>`, and Lambda
  network interfaces AWS hasn't released yet
- the log groups `/aws/lambda/cnq-path-extender-<hub>` and
  `/aws/codebuild/spoke-build-<hub>`
- hub nodes still carrying the CDF security group
- objects, old versions and delete markers under `s3://<state_bucket>/<hub>/`

It doesn't check spokes: run `spoke/cleanup.py check` for each spoke region too.

---

## Updating

The control plane doesn't pull updates from anywhere; it runs the copy of the code you
deployed it from. To change it:

- **Spoke stack (`spoke/`):** edit your copy, then re-run `terraform apply` in
  `bootstrap/`. That uploads the new bundle; the next launch uses it.
- **Control plane (Lambdas, workflows, defaults):** edit, then re-run `terraform apply`
  in `bootstrap/`.

**Qumulo Terraform provider:** spokes are built with version **1.4.22** of the Qumulo
Terraform provider for AWS, set by `spoke/cluster/.terraform.lock.hcl`. To use another
version, set it in `spoke/cluster/versions.tf` (for example `version = "= 1.4.31"`), then
update the lock file, including Linux checksums for CodeBuild:

```bash
terraform -chdir=spoke/cluster init -upgrade -backend=false
```

```bash
terraform -chdir=spoke/cluster providers lock -platform=linux_amd64 -platform=windows_amd64
```

Then re-run `terraform apply` in `bootstrap/`. New spokes use the new version; existing
spokes switch the next time their cluster stack is applied or destroyed.

**Hub upgrades:** spokes must match the hub's Qumulo Core version. New spokes always
match automatically. Existing spokes must be upgraded through the Qumulo UI or API
when the hub is.

---

## Costs at a glance

Prices below are rough on-demand estimates; check AWS's current pricing for your
regions.

- **Control plane, idle:** about $0–1/month.
- **Each launch:** under about $0.50 (CodeBuild, the provider's provisioner instance,
  workflow).
- **Each running spoke:** runs 24/7 until you run destroy-spoke, whether or not anything
  uses it. Mostly EC2. Example: 3 × i4i.xlarge in eu-central-1 is about $1.28/hour
  (~$31/day) including the NAT gateway, plus EBS, S3 storage, and about $0.02/GB of
  cross-region traffic from the hub. The default size, 3 × i7i.8xlarge, costs far more.
  Qumulo licensing is separate.
- **Compute instance:** billed while it runs, until you terminate it or remove the
  spoke. Large GPU types cost tens of dollars an hour (a g5.48xlarge is about
  $16/hour).
- **Capacity reservation:** billed like a running instance of that type from the moment
  it's made, before the spoke exists. The launch normally uses it within about 10
  minutes. A failed deploy or compute launch cancels it; otherwise it expires after 3
  hours.
- **PCS cluster:** the PCS controller and the login node run until the spoke is removed.
  Compute nodes cost only while they run, plus the boot time and `idle_minutes` tail
  each time one starts.
- **Local mode:** the compute instance and PCS cluster cost the same as on a spoke,
  without the spoke.

Nothing is removed automatically, including after a failed launch. Remove spokes (and
local deployments) when you're done with them.
