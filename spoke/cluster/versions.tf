terraform {
  required_version = ">= 1.11.0"

  required_providers {
    qumulo = {
      source  = "qumulo-terraform-registry.s3.us-east-1.amazonaws.com/qumulo/qumulo"
      version = "~> 1.4.22"
    }
  }

  # Partial configuration. The buildspec supplies bucket, region, and
  # key = <hub>/spokes/<region>/cluster.tfstate
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "qumulo" {
  aws {}
}
