locals {
  # Retries shared by every Lambda task.
  lambda_retry = jsonencode({
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2
  })

  # A cluster that briefly doesn't answer (e.g. right after quorum forms).
  connection_retry = jsonencode({
    ErrorEquals     = ["ConnectionError"]
    IntervalSeconds = 30
    MaxAttempts     = 5
    BackoffRate     = 2
  })

  workflow_vars = {
    hub_name          = local.hub
    hub_uuid          = local.hub_probe.cluster_uuid
    lambda_arn        = aws_lambda_function.portal.arn
    codebuild_project = aws_codebuild_project.spoke.name
    topic_arn         = aws_sns_topic.notify.arn
    lambda_retry      = local.lambda_retry
    connection_retry  = local.connection_retry
  }
}

# Step Functions checks at creation that the role can manage the EventBridge rule behind
# codebuild:startBuild.sync, so the policy has to exist first.
resource "aws_sfn_state_machine" "deploy" {
  name       = "deploy-spoke-${local.hub}"
  role_arn   = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/../workflows/deploy-spoke.asl.json", local.workflow_vars)

  depends_on = [aws_iam_role_policy.sfn]
}

resource "aws_sfn_state_machine" "refresh_hub" {
  name       = "refresh-hub-${local.hub}"
  role_arn   = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/../workflows/refresh-hub.asl.json", local.workflow_vars)

  depends_on = [aws_iam_role_policy.sfn]
}

resource "aws_sfn_state_machine" "destroy" {
  name       = "destroy-spoke-${local.hub}"
  role_arn   = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/../workflows/destroy-spoke.asl.json", local.workflow_vars)

  depends_on = [aws_iam_role_policy.sfn]
}
