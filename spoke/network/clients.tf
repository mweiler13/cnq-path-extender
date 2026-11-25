# -----------------------------------------------------------------------------
# For clients in the spoke VPC: the optional compute instance (launched by the deploy
# workflow, not by Terraform: it retries until capacity turns up), or instances you
# launch yourself. Created only when client_resources is set; a compute launch sets it.
# -----------------------------------------------------------------------------

locals {
  clients = var.client_resources ? 1 : 0
}

# The cluster already allows the whole spoke VPC (allow_cidrs), so this only needs
# outbound access, plus SSH from the hub VPC.
resource "aws_security_group" "client" {
  count = local.clients

  name        = "${local.name}-clients"
  description = "Clients of the ${var.region} spoke, e.g. the compute instance"
  vpc_id      = aws_vpc.spoke.id

  tags = { Name = "${local.name}-clients" }
}

resource "aws_vpc_security_group_egress_rule" "client_all" {
  count = local.clients

  security_group_id = aws_security_group.client[0].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "client_ssh_from_hub" {
  count = local.clients

  security_group_id = aws_security_group.client[0].id
  description       = "SSH from the hub VPC"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.hub_vpc_cidr
}

# Session Manager access, so an instance is reachable without a network path to it.
resource "aws_iam_role" "client" {
  count = local.clients

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
  count = local.clients

  role       = aws_iam_role.client[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "client" {
  count = local.clients

  name = "${local.name}-compute"
  role = aws_iam_role.client[0].name
}
