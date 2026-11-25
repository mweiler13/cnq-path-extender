# AWS PCS (managed Slurm) in the spoke's private subnet: a login node, compute nodes that
# scale from zero, and one queue. Every node mounts the spoke; the login node also sets
# up the chosen pipeline. Built after the portal is up, so the spoke's IPs are known.

# The spoke's network and node IPs come from its other stacks' state. Local mode
# (spoke/local/) passes them in instead, as var.network.
data "terraform_remote_state" "network" {
  count   = var.network == null ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.network_state_key
    region = var.state_region
  }
}

data "terraform_remote_state" "cluster" {
  count   = var.network == null ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.cluster_state_key
    region = var.state_region
  }
}

locals {
  # Attribute by attribute: a conditional between var.network and the remote state's
  # outputs is a type error when var.network is null (spokes).
  net = {
    vpc_id            = try(var.network.vpc_id, data.terraform_remote_state.network[0].outputs.vpc_id)
    private_subnet_id = try(var.network.subnet_id, data.terraform_remote_state.network[0].outputs.private_subnet_id)
  }
  nfs_hosts = var.network != null ? var.network.nfs_hosts : try(data.terraform_remote_state.cluster[0].outputs.primary_ips, [])

  # The spoke's region, or "local" in local mode: in names and the spoke-region tag.
  site = coalesce(var.site, var.region)

  # IAM names follow the other per-spoke roles (<hub>-<region>-compute), which cleanup.py knows.
  name = "${var.hub_name}-${local.site}-pcs"
  # PCS cluster names are short; the hash keeps two hubs' spokes in one region apart.
  cluster_name = "pcs-${substr(sha1(var.hub_name), 0, 6)}-${replace(local.site, "-", "")}"

  tags = merge(var.extra_tags, {
    "cnq-path-extender:hub"          = var.hub_name
    "cnq-path-extender:spoke-region" = local.site
  })

  # PCS shows Slurm physical cores only (one thread per core). Jobs asking for more CPUs or
  # memory than a node has would never start, so the pipelines' limits come from these.
  node_cpus      = data.aws_ec2_instance_type.compute.default_cores
  node_memory_gb = floor(data.aws_ec2_instance_type.compute.memory_size * 0.9 / 1024)
}

# AWS's PCS sample AMI for this Slurm version: Amazon Linux 2023 with the PCS agent and
# Slurm. Fine for testing; AWS doesn't support it for production.
data "aws_ami" "pcs" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["aws-pcs-sample_ami-al2023-x86_64-slurm-${var.slurm_version}*"]
  }
}

data "aws_ec2_instance_type" "compute" {
  instance_type = var.pcs.compute_instance_type
}

# -----------------------------------------------------------------------------
# Network: the controller and every node talk to each other freely; NFS to the spoke is
# already allowed (the cluster accepts the whole spoke VPC).
# -----------------------------------------------------------------------------

resource "aws_security_group" "pcs" {
  name        = local.name
  description = "PCS controller and nodes for the ${local.site} site of hub ${var.hub_name}"
  vpc_id      = local.net.vpc_id

  ingress {
    description = "Slurm and node-to-node traffic"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }

  egress {
    description = "Spoke NFS, AWS APIs, and the internet through the NAT gateway"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# Node role. PCS requires the role's name to start with AWSPCS or its path to be /aws-pcs/.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = local.name
  path = "/aws-pcs/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "node" {
  name = "pcs-node"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "RegisterWithPcs"
      Effect   = "Allow"
      Action   = "pcs:RegisterComputeNodeGroupInstance"
      Resource = "*"
    }]
  })
}

# Session Manager for access; S3 read for pipeline references (e.g. Sarek's iGenomes).
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# The S3 read above would otherwise include the state bucket, whose network state holds
# the spoke's admin password and SSH key. Jobs on the cluster never need it.
resource "aws_iam_role_policy" "deny_state" {
  name = "deny-state-bucket"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "NoStateBucket"
      Effect   = "Deny"
      Action   = "s3:*"
      Resource = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = local.name
  path = "/aws-pcs/"
  role = aws_iam_role.node.name
}
