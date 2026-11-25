# -----------------------------------------------------------------------------
# Local mode (docs/local-mode.md): the modules (compute instance, PCS cluster) in the
# hub's own VPC, mounting the hub directly, with no spoke. The same-region baseline for
# work run on a spoke.
# -----------------------------------------------------------------------------

locals {
  local_workflow_vars = merge(local.workflow_vars, { hub_region = var.hub_region })
}

resource "aws_sfn_state_machine" "deploy_local" {
  name       = "deploy-local-${local.hub}"
  role_arn   = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/../workflows/deploy-local.asl.json", local.local_workflow_vars)

  depends_on = [aws_iam_role_policy.sfn]
}

resource "aws_sfn_state_machine" "destroy_local" {
  name       = "destroy-local-${local.hub}"
  role_arn   = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/../workflows/destroy-local.asl.json", local.local_workflow_vars)

  depends_on = [aws_iam_role_policy.sfn]
}

# The Lambda reads local mode's state (the compute instance's network) and deletes it once
# destroy-local's check is clean.
resource "aws_iam_role_policy" "lambda_local" {
  name = "local-mode"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadLocalState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/${local.hub}/local/*"
      },
      {
        Sid       = "ListLocalState"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = "arn:aws:s3:::${var.state_bucket}"
        Condition = { StringLike = { "s3:prefix" = "${local.hub}/local/*" } }
      },
    ]
  })
}

output "deploy_local_state_machine_arn" {
  description = "Local mode: deploy modules in the hub's VPC (see docs/local-mode.md)."
  value       = aws_sfn_state_machine.deploy_local.arn
}

output "destroy_local_state_machine_arn" {
  description = "Local mode: remove what deploy-local created."
  value       = aws_sfn_state_machine.destroy_local.arn
}
