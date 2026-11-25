# Launch templates (one per node group: the login node also gets the pipeline setup) and
# the PCS cluster, node groups, and queue.

locals {
  # Settings for the node scripts, written to /etc/cnq-path-extender.env on each node.
  node_env = merge(
    {
      PA_HUB        = var.hub_name
      PA_REGION     = var.region
      PA_SPOKE_PATH = var.path
      PA_MOUNT_ROOT = "/mnt/qumulo"
      # lookupcache=positive: files created on other nodes are visible at once (by default
      # a missing file can stay "missing" for up to 30 s, which delays Nextflow noticing
      # each finished task).
      PA_NFS_OPTIONS       = "vers=3,tcp,hard,nconnect=16,rsize=1048576,wsize=1048576,noatime,lookupcache=positive"
      PA_NFS_HOSTS         = join(" ", local.nfs_hosts)
      PA_SHARED            = "/mnt/qumulo/pcs"
      PA_SLURM_BIN         = "/opt/aws/pcs/scheduler/slurm-${var.slurm_version}/bin"
      PA_QUEUE             = "compute"
      PA_NODE_CPUS         = tostring(local.node_cpus)
      PA_NODE_MEMORY_GB    = tostring(local.node_memory_gb)
      PA_IDLE_MINUTES      = tostring(var.pcs.idle_minutes)
      PA_NEXTFLOW_VERSION  = var.nextflow_version
      PA_APPTAINER_VERSION = var.apptainer_version
      PA_PIPELINE          = var.pcs.pipeline
    },
    { for k, v in var.pcs.pipeline_options : "APP_${upper(k)}" => v },
  )
  env_file = join("\n", [for k, v in local.node_env : "${k}='${replace(v, "'", "'\\''")}'"])

  # PCS caps user data at 13,384 bytes (it adds its own), so the scripts go in compressed
  # (gzip, then base64) and without their comment lines (not #!).
  strip_comments  = "/(?m)^[ \\t]*#([^!\\n].*)?\\n/"
  pipeline_script = var.pcs.pipeline == "" ? "" : replace(file("${path.module}/pipelines/${var.pcs.pipeline}.sh"), local.strip_comments, "")
  setup_script    = replace(file("${path.module}/node/setup.sh"), local.strip_comments, "")
  libexec         = "/usr/local/libexec/cnq-path-extender"

  # PCS merges its own user data with ours, so ours must be MIME multi-part.
  user_data = {
    for role in ["login", "compute"] : role => join("\n", [
      "MIME-Version: 1.0",
      "Content-Type: multipart/mixed; boundary=\"==PA==\"",
      "",
      "--==PA==",
      "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
      "",
      "#!/bin/bash",
      "cat > /etc/cnq-path-extender.env <<'PA_ENV'",
      local.env_file,
      "PA_ROLE='${role}'",
      "PA_ENV",
      "mkdir -p ${local.libexec}",
      "base64 -d <<'PA_PIPELINE' | gunzip > ${local.libexec}/pipeline.sh",
      base64gzip(role == "login" ? local.pipeline_script : ""),
      "PA_PIPELINE",
      "base64 -d <<'PA_SETUP' | gunzip > ${local.libexec}/setup.sh",
      base64gzip(local.setup_script),
      "PA_SETUP",
      "exec /bin/bash ${local.libexec}/setup.sh",
      "",
      "--==PA==--",
      "",
    ])
  }

  node_groups = {
    login   = { instance_type = var.pcs.login_instance_type, min = 1, max = 1 }
    compute = { instance_type = var.pcs.compute_instance_type, min = 0, max = var.pcs.max_nodes }
  }
}

resource "aws_launch_template" "node" {
  for_each = local.node_groups

  name                   = "${local.name}-${each.key}"
  vpc_security_group_ids = [aws_security_group.pcs.id]
  user_data              = base64encode(local.user_data[each.key])

  # Hop limit 2: containers on the node can reach instance metadata (for S3 access).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.pcs.root_volume_gb
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # PCS launches the instances, so the provider's default tags don't reach them; these do.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-${each.key}", "cnq-path-extender:role" = "pcs-${each.key}" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  lifecycle {
    precondition {
      condition     = length(local.user_data[each.key]) < 13384
      error_message = "The ${each.key} node's user data is ${length(local.user_data[each.key])} bytes; PCS allows under 13,384 (it adds its own). The scripts are compressed already: shorten spoke/pcs/node/setup.sh or the pipeline script."
    }
    precondition {
      condition     = length(local.nfs_hosts) > 0
      error_message = "The spoke cluster has no node IPs in its state: build the cluster first."
    }
  }
}

resource "awscc_pcs_cluster" "this" {
  name = local.cluster_name
  size = "SMALL"

  scheduler = {
    type    = "SLURM"
    version = var.slurm_version
  }

  # Idle compute nodes stop after this. It should exceed a pipeline's longest single task,
  # or the other nodes stop and must boot again mid-run (PCS's default is 10 minutes).
  slurm_configuration = {
    scale_down_idle_time_in_seconds = var.pcs.idle_minutes * 60
  }

  networking = {
    subnet_ids         = [local.net.private_subnet_id]
    security_group_ids = [aws_security_group.pcs.id]
  }

  tags = local.tags
}

resource "awscc_pcs_compute_node_group" "node" {
  for_each = local.node_groups

  cluster_id               = awscc_pcs_cluster.this.cluster_id
  name                     = each.key
  ami_id                   = data.aws_ami.pcs.id
  iam_instance_profile_arn = aws_iam_instance_profile.node.arn
  subnet_ids               = [local.net.private_subnet_id]
  purchase_option          = "ONDEMAND"

  custom_launch_template = {
    template_id = aws_launch_template.node[each.key].id
    version     = tostring(aws_launch_template.node[each.key].latest_version)
  }

  instance_configs = [{ instance_type = each.value.instance_type }]

  scaling_configuration = {
    min_instance_count = each.value.min
    max_instance_count = each.value.max
  }

  tags = local.tags

  # The role's policies must be in place before nodes try to register.
  depends_on = [aws_iam_role_policy.node, aws_iam_role_policy_attachment.node]
}

resource "awscc_pcs_queue" "compute" {
  cluster_id = awscc_pcs_cluster.this.cluster_id
  name       = "compute"

  compute_node_group_configurations = [
    { compute_node_group_id = awscc_pcs_compute_node_group.node["compute"].compute_node_group_id },
  ]

  tags = local.tags
}
