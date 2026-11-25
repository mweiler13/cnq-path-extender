# Applications for the compute instance

Each `<name>.sh` here is an application the deploy workflow can set up on the optional
compute instance, selected with `"compute": {"application": "<name>"}`. To add one, add a
file: the file name is the application name, and nothing else needs registering.

The script is appended to the instance's user data after
[`../compute/base.sh`](../compute/base.sh) and runs as root at first boot. It runs on the
default AMI for the instance type (Amazon Linux 2023 for types without GPUs, and the AWS
Deep Learning Base OSS NVIDIA Driver GPU AMI, which adds Docker and the NVIDIA container
toolkit, for types with GPUs), or on a custom AMI (`compute.ami_id`) if one is given. A
custom AMI must provide whatever the application needs, so a script should check for its
prerequisites and report clearly when they're missing (`parabricks.sh` checks for
Docker). An application configures the instance for itself, including OS settings
(`parabricks.sh` sets Linux's writeback, for example).

An application that only makes sense on GPU types says so in its header, and Validate
then refuses instance types without GPUs:

```bash
# requires: gpu
```

Available to the script, as environment variables. `PA_` variables are the tool's own
("path-extender") settings; `APP_` variables are the launch's `application_options`.

| Name | What it is |
|---|---|
| `PA_MOUNT_ROOT` | Where the spoke is mounted (`/mnt/qumulo`). The mount happens in the background once the spoke is ready, so don't wait for it here. |
| `PA_SPOKE_PATH` | The portal path; data is at `${PA_MOUNT_ROOT}${PA_SPOKE_PATH}`. |
| `PA_SCRATCH` | Fast local scratch directory (NVMe instance storage when the type has it), owned by `PA_USER`. |
| `PA_USER` | The image's login user (`ec2-user` on Amazon Linux). |
| `PA_REGION`, `PA_HUB` | Spoke region and hub name. |
| `APP_<NAME>` | Each `compute.application_options` entry, name upper-cased (`version` → `APP_VERSION`). |
| `pa_status "<text>"` | Records progress in `/var/lib/cnq-path-extender/status`. |

All of these are also in `/etc/cnq-path-extender.env` for scripts the application installs.

Guidelines:

- Don't exit: a failure should be reported with `pa_status "ERROR: ..."`, not end the
  user data, so the instance stays usable.
- The spoke squashes root, so anything that writes to the spoke must run as the calling
  user (see `parabricks.sh`'s `pbrun` wrapper).
- Document the options at the top of the file.
- User data, including `base.sh`, is limited to 16 KB.
