# CDF security group, attached once to the hub via its additional_security_group_ids.
# Deliberately has no inline rules: each spoke adds its own TCP 3713 ingress rule as a
# separate resource in the spoke stack, so neither side overwrites the other.
resource "aws_security_group" "cdf" {
  name        = "cdf-${local.hub}"
  description = "Cloud Data Fabric access to hub ${local.hub} from cnq-path-extender spokes"
  vpc_id      = data.aws_vpc.hub.id

  tags = { Name = "cdf-${local.hub}" }
}

# The hub VPC's default security group. Used only as a parking spot for the Lambda's
# network interfaces when the Lambda is destroyed (see lambda.tf); never modified.
data "aws_security_group" "hub_default" {
  vpc_id = data.aws_vpc.hub.id
  name   = "default"
}

# Portal Lambda: outbound only (hub API, spoke APIs over peering, AWS APIs via NAT).
resource "aws_security_group" "lambda" {
  name        = "cnq-path-extender-lambda-${local.hub}"
  description = "cnq-path-extender portal Lambda for hub ${local.hub}"
  vpc_id      = data.aws_vpc.hub.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cnq-path-extender-lambda-${local.hub}" }

  # Safety net: wait (rather than fail at the 15-minute default) if AWS is slow to
  # release Lambda network interfaces despite the swap in lambda.tf.
  timeouts {
    delete = "45m"
  }
}
