# Local mode: what a compute instance needs in the hub's VPC. A security group (outbound
# only; the hub already allows NFS from its VPC) and a Session Manager role. Outputs use
# the spoke network stack's names, which the compute Lambda reads.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # Partial configuration. local/build.sh supplies bucket, region, and
  # key = <hub>/local/network.tfstate
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

variable "region" {
  description = "The hub's region."
  type        = string
}

variable "hub_name" {
  description = "Hub deployment unique name."
  type        = string
}

variable "extra_tags" {
  description = "Tags added to every resource (from bootstrap's extra_tags)."
  type        = map(string)
  default     = {}
}

variable "local_vpc_id" {
  description = "The hub's VPC."
  type        = string
  default     = ""
}

variable "local_subnet_id" {
  description = "The hub nodes' subnet."
  type        = string
  default     = ""
}

variable "local_availability_zone" {
  description = "The hub nodes' zone."
  type        = string
  default     = ""
}

locals {
  name = "${var.hub_name}-local"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.extra_tags, {
      "cnq-path-extender:hub"          = var.hub_name
      "cnq-path-extender:spoke-region" = "local"
    })
  }
}

resource "aws_security_group" "client" {
  name        = "${local.name}-clients"
  description = "Local-mode clients of hub ${var.hub_name}, e.g. the compute instance"
  vpc_id      = var.local_vpc_id

  lifecycle {
    precondition {
      condition     = startswith(var.local_vpc_id, "vpc-") && startswith(var.local_subnet_id, "subnet-")
      error_message = "local_vpc_id and local_subnet_id must be the hub's VPC and subnet (set by deploy-local)."
    }
  }

  egress {
    description = "All outbound"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-clients" }
}

resource "aws_iam_role" "client" {
  name = "${local.name}-compute"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "client_ssm" {
  role       = aws_iam_role.client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "client" {
  name = "${local.name}-compute"
  role = aws_iam_role.client.name
}

output "vpc_id" {
  description = "The hub's VPC (local mode's compute instance launches here)."
  value       = var.local_vpc_id
}

output "private_subnet_id" {
  description = "The hub nodes' subnet."
  value       = var.local_subnet_id
}

output "availability_zone" {
  description = "The hub nodes' zone."
  value       = var.local_availability_zone
}

output "client_security_group_id" {
  description = "Security group for local-mode clients, e.g. the compute instance."
  value       = aws_security_group.client.id
}

output "client_instance_profile_name" {
  description = "Session Manager instance profile for local-mode clients."
  value       = aws_iam_instance_profile.client.name
}

output "key_pair_name" {
  description = "Always null: local-mode clients are reached through Session Manager only."
  value       = null
}
