# PCS node setup, run as root at first boot before the PCS agent starts (so a node joins
# Slurm only once it's ready). Every node: packages, Apptainer, Slurm on PATH, the spoke
# mount, a login profile. The login node then sets up Nextflow and the pipeline in the
# background. Terraform's user data writes /etc/cnq-path-extender.env and pipeline.sh, then
# runs this (both scripts are compressed in the user data).
#
# Logs: /var/log/cnq-path-extender-setup.log. Progress: /var/lib/cnq-path-extender/status.

set -uo pipefail
set -a; . /etc/cnq-path-extender.env; set +a
mkdir -p /var/lib/cnq-path-extender
exec > >(tee -a /var/log/cnq-path-extender-setup.log) 2>&1
pa_status() { echo "$(date -Is) $*" | tee -a /var/lib/cnq-path-extender/status; }
pa_status "PCS $PA_ROLE node setup starting"

# Java and Python 3.12 run Nextflow and the xoos launcher, whose driver jobs run on compute
# nodes. Apptainer: see apptainer_version in variables.tf.
dnf install -y nfs-utils sysstat git java-17-amazon-corretto-headless python3.12 python3.12-pip ||
  pa_status "WARNING: package install failed"
apptainer --version 2>/dev/null | grep -q "$PA_APPTAINER_VERSION" ||
  dnf install -y "https://github.com/apptainer/apptainer/releases/download/v${PA_APPTAINER_VERSION}/apptainer-${PA_APPTAINER_VERSION}-1.x86_64.rpm" ||
  pa_status "WARNING: Apptainer install failed"

# PCS keeps Slurm outside the default PATH; jobs and non-login shells need it too.
for cmd in sbatch srun salloc squeue scancel scontrol sacct sinfo sstat sprio sshare; do
  ln -sf "$PA_SLURM_BIN/$cmd" /usr/local/bin/$cmd
done

# The spoke: each node first mounts a spoke node picked by its instance ID (falling back to
# the others), then moves to its turn in an even spread (below, once $PA_SHARED is there).
imds() {
  local t
  t=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') &&
    curl -sf -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}
read -r -a hosts <<< "$PA_NFS_HOSTS"
iid=$(imds instance-id) || iid=""
[[ $iid =~ ^i-[0-9a-f]{6,}$ ]] || iid=i-000000  # no metadata: start at the first host
start=$(( 0x${iid: -6} % ${#hosts[@]} ))
mkdir -p "$PA_MOUNT_ROOT"
mounted=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  for i in "${!hosts[@]}"; do
    host=${hosts[$(( (start + i) % ${#hosts[@]} ))]}
    if mount -t nfs -o "$PA_NFS_OPTIONS" "$host:/" "$PA_MOUNT_ROOT"; then mounted=$host; break 2; fi
  done
  sleep 30
done
[ -n "$mounted" ] || pa_status "ERROR: couldn't mount the spoke from any of: $PA_NFS_HOSTS"

# Shared on the spoke (outside the portal path, so it stays local): software, container
# cache, temp space, work directories, references, run directories.
#
# The export may map root to nobody (root squashing; the hub does), so root can't hand
# files to ec2-user. Root makes only the top directory, open to all (sticky, like /tmp);
# ec2-user, who runs every job, makes and owns everything under it.
mkdir -p "$PA_SHARED" && chmod 1777 "$PA_SHARED" 2>/dev/null
runuser -u ec2-user -- mkdir -p "$PA_SHARED"/{bin,software,conf,apptainer-cache,tmp,work,references,runs} ||
  pa_status "ERROR: ec2-user can't write to $PA_SHARED; check its owner and mode on the cluster"

# Even spread: by hash, a few nodes can pile onto one spoke node. So each node then takes
# the next spoke node in turn from a counter on the cluster (locked, so no two nodes get the
# same turn) and moves its mount there; if anything fails it keeps the first mount.
if [ -n "$mounted" ] && [ ${#hosts[@]} -gt 1 ]; then
  turn=$( (flock -w 60 9 || exit 1
           n=$(cat "$PA_SHARED/.mount-turn" 2>/dev/null); n=${n:-0}
           echo $((n + 1)) > "$PA_SHARED/.mount-turn" && echo "$n") 9>> "$PA_SHARED/.mount-turn.lock" ) || turn=""
  want=${turn:+${hosts[$(( turn % ${#hosts[@]} ))]}}
  if [ -n "$want" ] && [ "$want" != "$mounted" ] && umount "$PA_MOUNT_ROOT"; then
    if mount -t nfs -o "$PA_NFS_OPTIONS" "$want:/" "$PA_MOUNT_ROOT"; then mounted=$want
    else mount -t nfs -o "$PA_NFS_OPTIONS" "$mounted:/" "$PA_MOUNT_ROOT"; fi
  fi
  [ -n "$turn" ] || pa_status "WARNING: no mount turn (lock timed out); keeping $mounted"
fi
if [ -n "$mounted" ]; then
  echo "$mounted:/ $PA_MOUNT_ROOT nfs ${PA_NFS_OPTIONS},_netdev,nofail 0 0" >> /etc/fstab
  pa_status "mounted $mounted:/ on $PA_MOUNT_ROOT; data at ${PA_MOUNT_ROOT}${PA_SPOKE_PATH}"
fi

# The sample AMI's default java is newer than Nextflow accepts (17 to 25): use our 17.
# Finished images are shared (NXF_APPTAINER_CACHEDIR); Apptainer's own layer cache and
# build space stay on local disk: its cache locks hang on NFSv3, stalling every pull.
java17=$(ls -d /usr/lib/jvm/java-17-amazon-corretto* 2>/dev/null | head -1)
cat > /etc/profile.d/cnq-path-extender.sh <<PA_PROFILE
export PATH=$PA_SLURM_BIN:$PA_SHARED/bin:\$PATH
export PA_SHARED=$PA_SHARED PA_DATA=${PA_MOUNT_ROOT}${PA_SPOKE_PATH} PA_QUEUE=$PA_QUEUE PA_IDLE_MINUTES=$PA_IDLE_MINUTES
export NXF_JAVA_HOME=$java17
export NXF_HOME=$PA_SHARED/software/nextflow-home NXF_OPTS="-Xms512m -Xmx4g" NXF_ANSI_LOG=false
export NXF_APPTAINER_CACHEDIR=$PA_SHARED/apptainer-cache NXF_SINGULARITY_CACHEDIR=$PA_SHARED/apptainer-cache
export APPTAINER_CACHEDIR=/var/tmp/apptainer-cache APPTAINER_TMPDIR=/var/tmp
PA_PROFILE

if [ "$PA_ROLE" != login ]; then
  pa_status "setup finished; ready for jobs"
  exit 0
fi

# Login node: the rest takes minutes (downloads), so it runs in the background and the
# node joins Slurm meanwhile. "setup finished" in the status file means it's done.
cat > /usr/local/libexec/cnq-path-extender/login.sh <<'PA_LOGIN'
#!/bin/bash
set -uo pipefail
set -a; . /etc/cnq-path-extender.env; set +a
. /etc/profile.d/cnq-path-extender.sh
exec >> /var/log/cnq-path-extender-setup.log 2>&1
pa_status() { echo "$(date -Is) $*" | tee -a /var/lib/cnq-path-extender/status; }
# Everything on the shared storage is done as ec2-user (see the root squashing note), from
# its home: Nextflow writes .nextflow/ in the current directory, and ours is root's /.
as_user() { runuser -u ec2-user -- env -C /home/ec2-user HOME=/home/ec2-user "$@"; }

# Nextflow, once, on the shared storage (flock: a replaced login node may race the old one).
as_user bash -c '
  mkdir -p "$NXF_HOME"
  (
    flock 9
    if ! "$PA_SHARED/bin/nextflow" -version 2>/dev/null | grep -q "$PA_NEXTFLOW_VERSION"; then
      cd "$PA_SHARED/bin" && curl -fsSL https://get.nextflow.io | NXF_VER=$PA_NEXTFLOW_VERSION bash &&
        chmod 755 nextflow && ./nextflow -version >/dev/null
    fi
  ) 9> "$PA_SHARED/bin/.nextflow.lock"' && pa_status "Nextflow $PA_NEXTFLOW_VERSION ready" ||
  pa_status "ERROR: Nextflow install failed"

# Slurm and Apptainer for any Nextflow pipeline here: -c $PA_SHARED/conf/pcs.config
as_user tee "$PA_SHARED/conf/pcs.config" >/dev/null <<PA_CONFIG
// Written by cnq-path-extender: Slurm on this PCS cluster, containers with Apptainer.
// Limits are one compute node: $PA_NODE_CPUS CPUs (physical cores), $PA_NODE_MEMORY_GB GB.
process {
    executor       = 'slurm'
    queue          = '$PA_QUEUE'
    resourceLimits = [cpus: $PA_NODE_CPUS, memory: $PA_NODE_MEMORY_GB.GB, time: 72.h]
    // Nextflow leaves the trace's hostname empty under Slurm: each task notes its node.
    beforeScript   = 'echo \$HOSTNAME > \${NXF_TASK_WORKDIR:-\$PWD}/.command.host'
}
executor {
    queueSize       = 200
    submitRateLimit = '10/1s'
}
apptainer {
    enabled     = true
    autoMounts  = true
    runOptions  = '--userns'
    cacheDir    = '$PA_SHARED/apptainer-cache'
    pullTimeout = '2h'
}
// Per-task timings and I/O. Raw (epoch ms, bytes) so bench-summary and bench-steps can read it.
trace {
    enabled   = true
    overwrite = true
    raw       = true
    fields    = 'task_id,hash,native_id,name,status,exit,attempt,hostname,workdir,submit,start,complete,duration,realtime,%cpu,peak_rss,rchar,wchar,read_bytes,write_bytes'
}
timeline.overwrite = true
report.overwrite   = true
PA_CONFIG

# Run summary for any pipeline's trace: bench-summary OUTDIR|TRACE
as_user tee "$PA_SHARED/bin/bench-summary" >/dev/null <<'PA_BENCH'
#!/usr/bin/env python3
# Sums up one run from its Nextflow trace (raw format, as pcs.config writes it):
#   bench-summary OUTDIR|TRACE
# Pipeline time is first task submitted to last task complete. A run with failed or retried
# tasks isn't valid for timing. Billed node-hours add each node's boot and idle time before
# it powers off (BOOT_MIN, IDLE_MIN; defaults 5, as seen on PCS, and the cluster's idle_minutes).
import csv, glob, os, sys
if len(sys.argv) != 2: sys.exit("usage: bench-summary OUTDIR|TRACE")
p = sys.argv[1]
if os.path.isdir(p):
    t = sorted(glob.glob(os.path.join(p, "pipeline_info", "execution_trace_*.txt")))
    if not t: sys.exit(f"no trace in {p}/pipeline_info")
    p = t[-1]
rows = list(csv.DictReader(open(p), delimiter="\t"))
def n(r, k):
    try: return float(r.get(k) or 0)
    except ValueError: return 0.0
ran = [r for r in rows if n(r, "start") and n(r, "complete")]
if not ran: sys.exit(f"no finished tasks in {p} (raw trace needed)")
first = min(n(r, "submit") for r in rows if n(r, "submit"))
last = max(n(r, "complete") for r in ran)
def host(r):
    h = r.get("hostname") or "-"
    if h == "-" and r.get("workdir"):
        try: h = open(os.path.join(r["workdir"], ".command.host")).read().strip() or "-"
        except OSError: pass
    return h
boot_min = float(os.environ.get("BOOT_MIN", 5))
idle_min = float(os.environ.get("IDLE_MIN", os.environ.get("PA_IDLE_MINUTES", 20)))
# Each node is up from its first task to its last, except across a gap longer than the idle
# time, when it powers off and boots again: every stretch adds a boot and an idle tail.
tasks = {}
for r in ran:
    tasks.setdefault(host(r), []).append((n(r, "start"), n(r, "complete")))
span, stretches = {}, 0
for h, ts in tasks.items():
    ts.sort()
    a, b = ts[0]
    up = 0
    for s, e in ts[1:]:
        if s - b > idle_min * 6e4:
            up += b - a; stretches += 1; a = s
        b = max(b, e)
    span[h] = up + b - a; stretches += 1
busy = sum(span.values()) / 3.6e6
extra = (boot_min + idle_min) / 60
failed = sum(r.get("status") not in ("COMPLETED", "CACHED") for r in rows)
retried = sum(n(r, "attempt") > 1 for r in rows)
gb = lambda k: sum(n(r, k) for r in rows) / 1e9
print(f"trace          {p}")
print(f"pipeline time  {(last - first) / 6e4:.1f} min")
print(f"tasks          {len(rows)} ({failed} failed, {retried} retried): {'valid' if not failed and not retried else 'NOT valid for timing'}")
if set(span) <= {"-", ""}:
    print("nodes          unknown: no hostnames in the trace or the task folders (run before pcs.config noted them)")
else:
    print(f"nodes          {len(span)}: {', '.join(sorted(span))}")
    print(f"node-hours     {busy:.2f} busy, {busy + extra * stretches:.2f} billed (estimate, {stretches} boots)")
print(f"task I/O       read {gb('rchar'):.1f} GB, written {gb('wchar'):.1f} GB (storage: {gb('read_bytes'):.1f} / {gb('write_bytes'):.1f} GB)")
PA_BENCH
as_user chmod 755 "$PA_SHARED/bin/bench-summary"

# Cost of each step, for comparing runs with each other and with published traces:
#   bench-steps OUTDIR|TRACE [OUTDIR|TRACE ...]
as_user tee "$PA_SHARED/bin/bench-steps" >/dev/null <<'PA_STEPS'
#!/usr/bin/env python3
# Per process (step): finished tasks, task-hours, CPU-hours (realtime x %cpu), longest task.
import collections, csv, glob, os, sys
if len(sys.argv) < 2: sys.exit("usage: bench-steps OUTDIR|TRACE [OUTDIR|TRACE ...]")
def f(v):
    try: return float(v)
    except (TypeError, ValueError): return 0.0
for p in sys.argv[1:]:
    t = p
    if os.path.isdir(p):
        t = sorted(glob.glob(os.path.join(p, "pipeline_info", "execution_trace_*.txt")))
        if not t: sys.exit(f"no trace in {p}/pipeline_info")
        t = t[-1]
    s = collections.defaultdict(lambda: [0, 0.0, 0.0, 0.0])
    for r in csv.DictReader(open(t), delimiter="\t"):
        if r.get("status") != "COMPLETED": continue
        name = r["name"].split(" (")[0].split(":")[-1]
        rt = f(r.get("realtime")) / 3.6e6
        x = s[name]; x[0] += 1; x[1] += rt; x[2] += rt * f(r.get("%cpu")) / 100; x[3] = max(x[3], rt)
    print("==", p)
    print(f"{'step':40}{'tasks':>6}{'task-h':>9}{'CPU-h':>9}{'longest min':>12}")
    for name, x in sorted(s.items(), key=lambda kv: -kv[1][2]):
        print(f"{name:40}{x[0]:>6}{x[1]:>9.2f}{x[2]:>9.2f}{x[3] * 60:>12.1f}")
    print(f"{'TOTAL':40}{sum(x[0] for x in s.values()):>6}{sum(x[1] for x in s.values()):>9.2f}{sum(x[2] for x in s.values()):>9.2f}")
PA_STEPS
as_user chmod 755 "$PA_SHARED/bin/bench-steps"

pipeline_ok=true
if [ -n "$PA_PIPELINE" ]; then
  pa_status "setting up pipeline: $PA_PIPELINE"
  if as_user bash /usr/local/libexec/cnq-path-extender/pipeline.sh; then
    pa_status "pipeline $PA_PIPELINE ready"
  else
    pipeline_ok=false
    pa_status "ERROR: pipeline $PA_PIPELINE setup failed; see /var/log/cnq-path-extender-setup.log"
  fi
fi
$pipeline_ok && pa_status "setup finished (pipeline: ${PA_PIPELINE:-none}); ready to use"
PA_LOGIN
systemd-run --unit=cnq-path-extender-login-setup --no-block /bin/bash /usr/local/libexec/cnq-path-extender/login.sh
pa_status "base setup done; Nextflow and pipeline setup continue in the background"
