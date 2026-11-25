data "archive_file" "portal" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/portal"
  output_path = "${path.module}/build/portal.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "portal" {
  name              = "/aws/lambda/cnq-path-extender-${local.hub}"
  retention_in_days = 30
}

resource "aws_lambda_function" "portal" {
  function_name    = "cnq-path-extender-${local.hub}"
  description      = "Hub/spoke portal operations for hub ${local.hub}"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.portal.output_path
  source_code_hash = data.archive_file.portal.output_base64sha256
  timeout          = 900
  memory_size      = 1024 # clients for ~30 regions in parallel (capacity search)

  # Inside the hub VPC: reaches the hub directly and spokes over peering.
  vpc_config {
    subnet_ids         = local.hub_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  # AWS keeps a VPC Lambda's network interfaces for up to ~45 minutes after the function
  # is deleted, which blocks deleting its security group. Before destroying the function,
  # move it onto the VPC's default group so ours is free to delete at once; the lingering
  # interfaces are then cleaned up by AWS in the background without blocking anything.
  replace_security_groups_on_destroy = true
  replacement_security_group_ids     = [data.aws_security_group.hub_default.id]

  environment {
    variables = {
      HUB_NAME              = local.hub
      HUB_REGION            = var.hub_region
      HUB_VPC_ID            = data.aws_vpc.hub.id
      HUB_VPC_CIDR          = data.aws_vpc.hub.cidr_block
      HUB_SECRET_ARN        = var.hub_admin_secret_arn
      STATE_BUCKET          = var.state_bucket
      DEFAULT_INSTANCE_TYPE = var.default_instance_type
      DEFAULT_NODE_COUNT    = tostring(var.default_node_count)
      PORTAL_TYPE           = var.portal_type
      EXTRA_TAGS            = jsonencode(var.extra_tags) # for the compute instance it launches
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.portal,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy.lambda,
  ]
}

# Confirms at bootstrap that the hub answers from inside its VPC and records its
# identity and version. A failure here stops bootstrap with the Lambda's error. The
# Lambda looks up the hub's node IPs itself each time, so new hub nodes need no
# bootstrap run; the refresh-hub workflow points existing spoke portals at them.
resource "aws_lambda_invocation" "probe_hub" {
  function_name = aws_lambda_function.portal.function_name
  input         = jsonencode({ action = "probe_hub" })

  triggers = {
    code = data.archive_file.portal.output_base64sha256
    ips  = join(",", local.hub_ips)
  }
}

locals {
  hub_probe = jsondecode(aws_lambda_invocation.probe_hub.result)
}
