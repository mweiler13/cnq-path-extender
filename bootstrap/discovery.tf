# Read-only lookups: find the hub cluster by its tag and derive its network.

data "aws_caller_identity" "current" {}

data "aws_instances" "hub" {
  instance_state_names = ["running"]

  filter {
    name   = "tag:Qumulo-Cluster"
    values = [var.hub_deployment_unique_name]
  }
}

data "aws_instance" "hub" {
  for_each    = toset(data.aws_instances.hub.ids)
  instance_id = each.value
}

data "aws_subnet" "hub" {
  for_each = toset(local.hub_subnet_ids)
  id       = each.value
}

data "aws_vpc" "hub" {
  # A placeholder keeps the lookup from silently matching the default VPC; the
  # preconditions below stop the run with a clear message first.
  id = try(local.hub_vpc_ids[0], "vpc-not-found")

  lifecycle {
    precondition {
      condition     = length(data.aws_instances.hub.ids) > 0
      error_message = "No running EC2 instances tagged Qumulo-Cluster = ${var.hub_deployment_unique_name} in ${var.hub_region}. Check hub_deployment_unique_name and hub_region."
    }
    precondition {
      condition     = length(local.hub_vpc_ids) == 1
      error_message = "Hub instances span more than one VPC: ${join(", ", local.hub_vpc_ids)}."
    }
  }
}

# Route tables serving the hub's subnets: explicit associations, or the VPC's main table.
data "aws_route_tables" "hub_subnet" {
  for_each = toset(local.hub_subnet_ids)
  vpc_id   = data.aws_vpc.hub.id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "hub_main" {
  vpc_id = data.aws_vpc.hub.id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

locals {
  hub     = var.hub_deployment_unique_name
  account = data.aws_caller_identity.current.account_id
  hub_ips = sort(data.aws_instances.hub.private_ips)

  hub_subnet_ids = sort(distinct([for i in data.aws_instance.hub : i.subnet_id]))
  hub_vpc_ids    = distinct([for s in data.aws_subnet.hub : s.vpc_id])

  hub_route_table_ids = sort(distinct(flatten([
    for s, rt in data.aws_route_tables.hub_subnet :
    length(rt.ids) > 0 ? rt.ids : [data.aws_route_table.hub_main.id]
  ])))
}
