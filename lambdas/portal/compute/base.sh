# Common setup for every compute instance, run as root at first boot: NFS client, scratch,
# and the spoke mount. Written for Amazon Linux 2023 (the default AMIs); also handles
# apt-based images, for a custom AMI. Anything else a custom AMI needs, it brings itself.
# The Lambda prepends /etc/cnq-path-extender.env (PA_* and APP_* settings) and appends the
# chosen application's script from apps/.
#
# Logs: /var/log/cnq-path-extender-setup.log. Progress: /var/lib/cnq-path-extender/status.

set -uo pipefail
mkdir -p /var/lib/cnq-path-extender
exec > >(tee -a /var/log/cnq-path-extender-setup.log) 2>&1

pa_status() {
  echo "$(date -Is) $*" | tee -a /var/lib/cnq-path-extender/status
}

pa_status "setup starting"

# Client tools: NFS mount, nfsiostat/mountstats, iostat, and mdadm for scratch.
if command -v dnf >/dev/null; then
  dnf install -y nfs-utils sysstat tmux mdadm || pa_status "WARNING: package install failed; see the setup log"
elif command -v apt-get >/dev/null; then
  { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common sysstat tmux mdadm; } ||
    pa_status "WARNING: package install failed; see the setup log"
else
  pa_status "WARNING: no dnf or apt-get; install an NFS client yourself"
fi

# The image's login user: ec2-user on Amazon Linux, ubuntu on Ubuntu; root otherwise.
PA_USER=root
for u in ec2-user ubuntu; do
  if id -u "$u" >/dev/null 2>&1; then PA_USER=$u; break; fi
done
echo "PA_USER=$PA_USER" >> /etc/cnq-path-extender.env

# Local scratch for application temp files, on NVMe instance storage when the type has
# it. The Deep Learning AMI sets that up at /opt/dlami/nvme; on other images, the
# instance store disks are striped (RAID 0) and mounted at /scratch. Instance storage is
# wiped when the instance stops. Without any, scratch is on the root volume.
if mountpoint -q /opt/dlami/nvme; then
  PA_SCRATCH=/opt/dlami/nvme/scratch
else
  PA_SCRATCH=/scratch
  mkdir -p /scratch
  disks=$(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1}')
  if [ -n "$disks" ] && ! mountpoint -q /scratch; then
    count=$(echo "$disks" | wc -l)
    dev=$(echo "$disks" | head -1)
    if [ "$count" -gt 1 ]; then
      # shellcheck disable=SC2086
      mdadm --create /dev/md0 --level=0 --raid-devices="$count" $disks --run && dev=/dev/md0
    fi
    if mkfs.ext4 -q -F -E nodiscard "$dev" && mount -o noatime "$dev" /scratch; then
      pa_status "scratch: $count NVMe instance store disk(s) at /scratch"
    else
      pa_status "WARNING: couldn't set up NVMe scratch; using the root volume"
    fi
  fi
fi
mkdir -p "$PA_SCRATCH"
chown "$PA_USER:" "$PA_SCRATCH"
echo "PA_SCRATCH=$PA_SCRATCH" >> /etc/cnq-path-extender.env
pa_status "scratch: $PA_SCRATCH"

# The instance can come up before the cluster does. The deploy workflow tags it with the
# spoke's node IPs once the portal is active; this service waits for that tag (read from
# instance metadata), then mounts the spoke. It survives reboots via /etc/fstab.
#
# "setup finished" means both are done: the application's setup (end of this script) and
# the mount. Whichever finishes second records it, once.
cat > /usr/local/sbin/cnq-path-extender-finished <<'PA_FINISHED'
#!/bin/bash
mkdir /var/lib/cnq-path-extender/finished 2>/dev/null || exit 0
set -a; . /etc/cnq-path-extender.env; set +a
echo "$(date -Is) setup finished (application: ${PA_APP:-none}); ready to use" |
  tee -a /var/lib/cnq-path-extender/status
PA_FINISHED
chmod 755 /usr/local/sbin/cnq-path-extender-finished

mkdir -p "$PA_MOUNT_ROOT"
cat > /usr/local/sbin/cnq-path-extender-mount <<'PA_MOUNT'
#!/bin/bash
set -uo pipefail
set -a; . /etc/cnq-path-extender.env; set +a
log() { echo "$(date -Is) $*" | tee -a /var/lib/cnq-path-extender/status; }

mountpoint -q "$PA_MOUNT_ROOT" && exit 0

imds() {
  local token
  token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') || return 1
  curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

log "waiting for the spoke to be ready (cnq-path-extender:nfs-hosts tag)"
until hosts=$(imds tags/instance/cnq-path-extender:nfs-hosts) && [ -n "$hosts" ]; do
  sleep 30
done

for host in $hosts; do
  if mount -t nfs -o "$PA_NFS_OPTIONS" "${host}:/" "$PA_MOUNT_ROOT"; then
    grep -q " $PA_MOUNT_ROOT nfs " /etc/fstab ||
      echo "${host}:/ $PA_MOUNT_ROOT nfs ${PA_NFS_OPTIONS},_netdev,nofail 0 0" >> /etc/fstab
    log "mounted ${host}:/ on $PA_MOUNT_ROOT; data at ${PA_MOUNT_ROOT}${PA_SPOKE_PATH}"
    ln -sfn "${PA_MOUNT_ROOT}${PA_SPOKE_PATH}" "$(getent passwd "$PA_USER" | cut -d: -f6)/data"
    [ -e /var/lib/cnq-path-extender/app-done ] && /usr/local/sbin/cnq-path-extender-finished
    exit 0
  fi
  log "mount from ${host} failed; trying the next node"
done
log "mount failed on every node; retrying"
exit 1
PA_MOUNT
chmod 755 /usr/local/sbin/cnq-path-extender-mount

cat > /etc/systemd/system/cnq-path-extender-mount.service <<'PA_UNIT'
[Unit]
Description=Mount the cnq-path-extender spoke once it is ready
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cnq-path-extender-mount
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
PA_UNIT
systemctl daemon-reload
systemctl enable --now cnq-path-extender-mount.service

mkdir -p /etc/motd.d
cat > /etc/motd.d/30-cnq-path-extender <<PA_MOTD

  cnq-path-extender compute instance for the ${PA_REGION} spoke of hub ${PA_HUB}
    Spoke data:  ${PA_MOUNT_ROOT}${PA_SPOKE_PATH}  (also ~/data, once mounted)
    Scratch:     ${PA_SCRATCH}
    Application: ${PA_APP:-none}
    Progress:    cat /var/lib/cnq-path-extender/status

PA_MOTD
