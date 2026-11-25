locals {
  name = "${var.hub_name}-${var.region}"

  tags = merge(var.extra_tags, {
    "cnq-path-extender:hub"          = var.hub_name
    "cnq-path-extender:spoke-region" = var.region
  })

  # Private subnet gets half the VPC; the small public subnet only holds the NAT gateway.
  private_subnet_cidr = cidrsubnet(var.vpc_cidr, 1, 0)
  public_subnet_cidr  = cidrsubnet(var.vpc_cidr, 4, 8)

  # Standard AZs (no Local Zones) that offer the chosen instance type. The workflow may
  # pick one (e.g. where a compute instance found capacity); otherwise the first.
  cnq_azs = sort(setintersection(
    data.aws_availability_zones.standard.names,
    data.aws_ec2_instance_type_offerings.az.locations,
  ))
  az = var.availability_zone != "" ? var.availability_zone : try(local.cnq_azs[0], "")
}

data "aws_availability_zones" "standard" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "az" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}
