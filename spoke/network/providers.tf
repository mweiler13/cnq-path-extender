# Spoke region: the new VPC, secrets, and key pair.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Hub region: peering acceptance, hub-side routes, and the CDF security group rule.
provider "aws" {
  alias  = "hub"
  region = var.hub_region

  default_tags {
    tags = local.tags
  }
}
