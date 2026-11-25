terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    # PCS is only in the Cloud Control provider; hashicorp/aws has no PCS resources.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.110"
    }
  }

  # Partial configuration. The buildspec supplies bucket, region, and
  # key = <hub>/spokes/<region>/pcs.tfstate
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

provider "awscc" {
  region = var.region
}
