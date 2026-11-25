# The CNQ cluster, deployed after the network stack so the network exists before the
# cluster is planned.

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.network_state_key
    region = var.state_region
  }
}

locals {
  net             = data.terraform_remote_state.network.outputs
  deployment_name = coalesce(var.deployment_name, "spk${replace(var.region, "-", "")}")

  tags = merge(var.extra_tags, {
    "cnq-path-extender:hub"          = var.hub_name
    "cnq-path-extender:spoke-region" = var.region
  })
}

resource "qumulo_filesystem_aws" "spoke" {
  admin_password         = local.net.admin_password
  allow_cidrs            = var.allow_cidrs # whole-variable only; see variables.tf
  cluster_name           = local.deployment_name
  cluster_product_type   = var.cluster_product_type
  cluster_version        = var.cluster_version
  deletion_protection    = false # spokes are transient; destroy-spoke must succeed
  deployment_name        = local.deployment_name
  ec2_key_pair           = local.net.key_pair_name
  instance_type          = var.instance_type
  node_count             = var.node_count
  region                 = var.region
  soft_capacity_limit_tb = var.soft_capacity_limit_tb
  subnet_ids             = [local.net.private_subnet_id]
  tags                   = local.tags
  vpc_id                 = local.net.vpc_id

  timeouts {
    create = "${var.provider_timeout_minutes}m"
    delete = "${var.provider_timeout_minutes}m"
    update = "${var.provider_timeout_minutes}m"
  }
}
