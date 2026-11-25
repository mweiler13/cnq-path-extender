# -----------------------------------------------------------------------------
# Spoke VPC: one private subnet for the cluster, one public subnet for NAT.
# -----------------------------------------------------------------------------

resource "aws_vpc" "spoke" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = local.private_subnet_cidr
  availability_zone = local.az

  tags = { Name = "${local.name}-private" }

  lifecycle {
    precondition {
      condition     = contains(local.cnq_azs, local.az)
      error_message = length(local.cnq_azs) == 0 ? "No standard availability zone in ${var.region} offers ${var.instance_type}." : "availability_zone ${local.az} doesn't offer ${var.instance_type}. Zones that do: ${join(", ", local.cnq_azs)}."
    }
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = local.public_subnet_cidr
  availability_zone = local.az

  tags = { Name = "${local.name}-public" }
}

resource "aws_internet_gateway" "spoke" {
  vpc_id = aws_vpc.spoke.id

  tags = { Name = local.name }
}

# CNQ needs outbound internet (quorum formation, software download).
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "spoke" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = local.name }

  depends_on = [aws_internet_gateway.spoke]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.spoke.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.spoke.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.spoke.id

  tags = { Name = "${local.name}-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.spoke.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Required by CNQ: S3 gateway endpoint on the cluster subnet's route table.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.spoke.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name}-s3" }
}

# -----------------------------------------------------------------------------
# Cross-region peering to the hub.
# -----------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "to_hub" {
  vpc_id      = aws_vpc.spoke.id
  peer_vpc_id = var.hub_vpc_id
  peer_region = var.hub_region

  tags = { Name = "${local.name}-to-hub" }
}

resource "aws_vpc_peering_connection_accepter" "hub" {
  provider = aws.hub

  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id
  auto_accept               = true

  tags = { Name = "${local.name}-to-hub" }
}

resource "aws_route" "spoke_to_hub" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.hub_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.hub.id
}

resource "aws_route" "hub_to_spoke" {
  provider = aws.hub
  for_each = toset(var.hub_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.hub.id
}

# CDF needs only inbound TCP 3713 on the hub. The rule lives on the control plane's
# own security group, so the hub's provider-managed groups are never touched.
resource "aws_vpc_security_group_ingress_rule" "hub_cdf_from_spoke" {
  provider = aws.hub

  security_group_id = var.cdf_security_group_id
  description       = "CDF from spoke ${var.region}"
  ip_protocol       = "tcp"
  from_port         = 3713
  to_port           = 3713
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${local.name}-cdf" }
}
