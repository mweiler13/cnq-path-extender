terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }

  # Partial configuration, supplied at init:
  #   terraform init -backend-config=bucket=<state_bucket> -backend-config=region=<hub_region> \
  #                  -backend-config=key=<hub_deployment_unique_name>/bootstrap/terraform.tfstate
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.hub_region

  default_tags {
    tags = merge(var.extra_tags, {
      "cnq-path-extender:hub" = var.hub_deployment_unique_name
    })
  }
}
