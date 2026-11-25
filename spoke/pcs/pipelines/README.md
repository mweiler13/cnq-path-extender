# Pipelines for the PCS cluster

Each `<name>.sh` here sets up a Nextflow pipeline on the optional PCS cluster's login
node, selected with `"pcs": {"pipeline": "<name>"}`. The script installs the pipeline
and the commands to run it. It doesn't run the pipeline.

## How a script runs

1. Terraform (`spoke/pcs/nodes.tf`) puts the script, compressed and without its comment
   lines, into the login node's user data. Compute nodes don't get it.
2. At first boot, `spoke/pcs/node/setup.sh` sets up the node (packages, Apptainer,
   Slurm on `PATH`, the cluster mount), then continues in the background: it installs
   Nextflow on the shared storage, writes `$PA_SHARED/conf/pcs.config`, installs
   `bench-summary` and `bench-steps`, and finally runs the pipeline script.
3. The script runs **as `ec2-user`** (the cluster squashes root, so files on shared
   storage must be created by the user who runs jobs), from `/home/ec2-user`, with
   `bash`. A non-zero exit marks the setup failed in
   `/var/lib/cnq-path-extender/status`; its output is in
   `/var/log/cnq-path-extender-setup.log`.

The script can be run again: a replaced login node runs it again against the same
shared storage, so it should skip what's already there.

## Environment

`PA_` variables are the tool's own ("path-extender") settings, from
`/etc/cnq-path-extender.env` and `/etc/profile.d/cnq-path-extender.sh`. `APP_`
variables are the launch's `pipeline_options`.

| Name | What it is |
|---|---|
| `PA_SHARED` | Shared storage on the cluster, outside the portal path: `/mnt/qumulo/pcs`. Has `bin/` (on `PATH`), `software/`, `conf/`, `apptainer-cache/`, `tmp/`, `work/`, `references/`, `runs/`. |
| `PA_DATA` | The portal path's data: `/mnt/qumulo<path>`. Results written here reach the hub. |
| `PA_MOUNT_ROOT`, `PA_SPOKE_PATH` | `/mnt/qumulo` and the portal path |
| `PA_QUEUE` | The Slurm queue: `compute` |
| `PA_NODE_CPUS`, `PA_NODE_MEMORY_GB` | One compute node's physical cores, and 90% of its memory in GB |
| `PA_IDLE_MINUTES` | `pcs.idle_minutes` |
| `PA_PIPELINE` | The pipeline's name |
| `PA_HUB`, `PA_REGION` | Hub name and spoke region |
| `PA_NEXTFLOW_VERSION`, `PA_APPTAINER_VERSION`, `PA_SLURM_BIN`, `PA_NFS_HOSTS`, `PA_NFS_OPTIONS`, `PA_ROLE` | Node setup details |
| `NXF_HOME`, `NXF_JAVA_HOME`, `NXF_APPTAINER_CACHEDIR`, ... | Nextflow settings; `nextflow` is on `PATH` |
| `APP_<NAME>` | Each `pcs.pipeline_options` entry, name upper-cased (`version` becomes `APP_VERSION`) |

`pipeline_options` names must start with a letter and use only letters, digits and `_`.
Values may use only letters, digits and `. _ : / @ + = , -`. Validate rejects anything
else.

Commands the script installs for users should go in `$PA_SHARED/bin`. They should source
`/etc/profile.d/cnq-path-extender.sh`, submit Nextflow as a Slurm job (so the user can
log out), and pass `-c $PA_SHARED/conf/pcs.config`.

## Adding a pipeline

1. Add `<name>.sh` here. Document its options at the top of the file.
2. Add the name to `PCS_PIPELINES` in [`lambdas/portal/pcs.py`](../../../lambdas/portal/pcs.py)
   (the Lambda doesn't ship `spoke/`, so it can't list this folder).
3. Add the name to the `pcs.pipeline` validation in
   [`spoke/pcs/variables.tf`](../variables.tf).
4. Run `terraform apply` in `bootstrap/` to upload the new code.

Keep it short: the login node's user data, with `setup.sh` and this script compressed,
must stay under 13,384 bytes, and the plan fails if it doesn't.

## What's here

### sarek

[nf-core/sarek](https://nf-co.re/sarek), germline and somatic variant calling.

- Pulls the pipeline at `version` (default 3.7.1). Defaults for `genome`
  (`GATK.GRCh38`, from AWS's public iGenomes bucket) and `tools` (`haplotypecaller`).
- Writes `$PA_SHARED/conf/sarek-pcs.config`, which sets smaller per-process CPU and
  memory requests than Sarek's defaults, so several light tasks share a node. Retries
  still double the memory.
- Installs `sarek-samplesheet DIR [SAMPLE]`, which prints a samplesheet for the paired
  FASTQs in a directory, and `run-sarek SAMPLESHEET [OUTDIR] [-- more arguments]`,
  which submits Sarek to Slurm with `pcs.config` and `sarek-pcs.config`. With
  `SAREK_PROFILE=<profile>`, it runs one of nf-core's test profiles with Sarek's own
  requests instead of `sarek-pcs.config`.
- Uses references from `$PA_SHARED/references/igenomes` when that directory exists,
  else from S3.

### xoos

The Roche SBX Xoos pipeline ([xoosnf](https://github.com/Roche-AXELIOS/xoosnf)) with its
launcher and the public smoke test dataset.

- Clones `xoosnf` and `XOOS` at `xoosnf_ref` and `xoos_ref` (default: latest), builds
  the launcher in a virtualenv, and downloads the smoke dataset release `dataset`
  (default 1.1.0).
- Writes a launcher environment for Slurm and a `pcs` profile whose per-task CPUs,
  memory, time and HaplotypeCaller options are sized for the compute node types.
- Installs `run-xoos-smoke [OUTPUT_DIR]`, which submits the three smoke tests (BAM,
  demultiplexed FASTQ, basecall FASTQ).
