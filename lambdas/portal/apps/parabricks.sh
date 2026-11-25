# NVIDIA Parabricks: GPU-accelerated genomics (fq2bam, HaplotypeCaller, DeepVariant, ...).
# requires: gpu
#
# Needs Docker and the NVIDIA container toolkit. The default AMI for GPU types has both;
# a custom AMI (compute.ami_id) must provide them.
# Also shortens Linux's writeback (below), so a large-memory instance sends fq2bam's BAM
# to the spoke steadily instead of in large bursts.
#
# Options (compute.application_options):
#   version  container tag of nvcr.io/nvidia/clara/clara-parabricks (default 4.8.0-1)
#
# Leaves the image pulled and a pbrun wrapper on the PATH that runs it with the spoke
# data and scratch mounted at the same paths as on the host, as the calling user (the
# spoke squashes root). Example, from a directory under the spoke data:
#   pbrun fq2bam --ref ref.fasta --in-fq R1.fq.gz R2.fq.gz --out-bam out.bam \
#     --tmp-dir "$PA_SCRATCH"

PB_IMAGE="nvcr.io/nvidia/clara/clara-parabricks:${APP_VERSION:-4.8.0-1}"

# Send written data to the spoke after 1 second or once 512 MB is waiting, instead of
# Linux's defaults (30 seconds, or 10% of memory), which on a machine with hundreds of GB
# send the BAM in 15-25 GB bursts. The hard limit (vm.dirty_ratio) stays at its default,
# so the application is never throttled.
cat > /etc/sysctl.d/90-cnq-path-extender-writeback.conf <<'PA_SYSCTL'
vm.dirty_expire_centisecs = 100
vm.dirty_writeback_centisecs = 100
vm.dirty_background_bytes = 536870912
PA_SYSCTL
if sysctl -p /etc/sysctl.d/90-cnq-path-extender-writeback.conf; then
  pa_status "parabricks: write cache set to send after 1 s or 512 MB"
else
  pa_status "WARNING: parabricks: couldn't apply the write-cache settings; see the setup log"
fi

if ! command -v docker >/dev/null 2>&1; then
  pa_status "ERROR: parabricks: Docker isn't on this AMI; Parabricks needs Docker and the NVIDIA container toolkit"
fi
systemctl enable --now docker
usermod -aG docker "$PA_USER"

pa_status "parabricks: pulling $PB_IMAGE"
pulled=no
for _ in 1 2 3; do
  if docker pull "$PB_IMAGE"; then pulled=yes; break; fi
  sleep 30
done
if [ "$pulled" = yes ]; then
  pa_status "parabricks: image ready"
else
  pa_status "ERROR: parabricks: couldn't pull $PB_IMAGE; see the setup log"
fi

if docker run --rm --gpus all "$PB_IMAGE" nvidia-smi -L; then
  pa_status "parabricks: GPUs visible in the container"
else
  pa_status "WARNING: parabricks: no GPUs visible in the container"
fi

cat > /usr/local/bin/pbrun <<PA_PBRUN
#!/bin/bash
# Runs Parabricks from its container. The working directory must be under
# ${PA_MOUNT_ROOT} or ${PA_SCRATCH}, which are mounted at the same paths.
set -a; . /etc/cnq-path-extender.env; set +a
exec docker run --rm --gpus all --user "\$(id -u):\$(id -g)" \\
  -v "\${PA_MOUNT_ROOT}:\${PA_MOUNT_ROOT}" -v "\${PA_SCRATCH}:\${PA_SCRATCH}" \\
  -w "\$PWD" "${PB_IMAGE}" pbrun "\$@"
PA_PBRUN
chmod 755 /usr/local/bin/pbrun
