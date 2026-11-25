terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }

  # Partial configuration. The buildspec supplies bucket, region, and
  # key = <hub>/spokes/<region>/network.tfstate
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
