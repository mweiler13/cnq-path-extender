# -----------------------------------------------------------------------------
# Portal Lambda
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "cnq-path-extender-lambda-${local.hub}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  name = "portal"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadClusterCredentials"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          var.hub_admin_secret_arn,
          "arn:aws:secretsmanager:*:${local.account}:secret:cnq-path-extender/${local.hub}/*",
        ]
      },
      {
        Sid      = "DecryptSecretsWithCustomerKeys"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringLike = { "kms:ViaService" = "secretsmanager.*.amazonaws.com" }
        }
      },
      {
        # DeleteObject: destroy-spoke removes a spoke's files once its cleanup check is clean.
        Sid      = "ReadSpokeState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/${local.hub}/spokes/*"
      },
      {
        # Without ListBucket a missing state file reads as AccessDenied, not NoSuchKey.
        Sid       = "ListSpokeState"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = "arn:aws:s3:::${var.state_bucket}"
        Condition = { StringLike = { "s3:prefix" = "${local.hub}/spokes/*" } }
      },
      {
        Sid    = "ValidateNetwork"
        Effect = "Allow"
        Action = [
          "ec2:DescribeRegions", "ec2:DescribeVpcPeeringConnections", "ec2:DescribeInstances",
          # Compute instance: candidate zones, type checks, AMI, capacity reservations
          "ec2:DescribeAvailabilityZones", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
          "ec2:DescribeImages", "ec2:DescribeCapacityReservations",
          "servicequotas:GetServiceQuota", "servicequotas:GetAWSDefaultServiceQuota",
        ]
        Resource = "*"
      },
      # The capacity hunt: reservations must carry this hub's tag, and only those can be
      # cancelled.
      {
        Sid       = "ReserveComputeCapacity"
        Effect    = "Allow"
        Action    = "ec2:CreateCapacityReservation"
        Resource  = "arn:aws:ec2:*:${local.account}:capacity-reservation/*"
        Condition = { StringEquals = { "aws:RequestTag/cnq-path-extender:hub" = local.hub } }
      },
      {
        Sid       = "TagComputeCapacityAtCreation"
        Effect    = "Allow"
        Action    = "ec2:CreateTags"
        Resource  = "arn:aws:ec2:*:${local.account}:capacity-reservation/*"
        Condition = { StringEquals = { "ec2:CreateAction" = "CreateCapacityReservation" } }
      },
      {
        Sid       = "ReleaseComputeCapacity"
        Effect    = "Allow"
        Action    = "ec2:CancelCapacityReservation"
        Resource  = "arn:aws:ec2:*:${local.account}:capacity-reservation/*"
        Condition = { StringEquals = { "ec2:ResourceTag/cnq-path-extender:hub" = local.hub } }
      },
      # The optional compute instance. The instance and its volumes must carry this hub's tag;
      # the other resources RunInstances touches can't carry request tags.
      {
        Sid      = "LaunchComputeInstance"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = ["arn:aws:ec2:*:${local.account}:instance/*", "arn:aws:ec2:*:${local.account}:volume/*"]
        Condition = {
          StringEquals = { "aws:RequestTag/cnq-path-extender:hub" = local.hub }
        }
      },
      {
        Sid    = "LaunchComputeInstanceResources"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:*::image/*",
          "arn:aws:ec2:*:${local.account}:subnet/*",
          "arn:aws:ec2:*:${local.account}:security-group/*",
          "arn:aws:ec2:*:${local.account}:network-interface/*",
          "arn:aws:ec2:*:${local.account}:key-pair/*",
          "arn:aws:ec2:*:${local.account}:capacity-reservation/*",
        ]
      },
      {
        Sid       = "TagComputeInstanceAtLaunch"
        Effect    = "Allow"
        Action    = "ec2:CreateTags"
        Resource  = ["arn:aws:ec2:*:${local.account}:instance/*", "arn:aws:ec2:*:${local.account}:volume/*"]
        Condition = { StringEquals = { "ec2:CreateAction" = "RunInstances" } }
      },
      {
        # Mount settings tags, and removal on destroy-spoke: only this hub's instances.
        Sid       = "ManageComputeInstance"
        Effect    = "Allow"
        Action    = ["ec2:CreateTags", "ec2:TerminateInstances"]
        Resource  = "arn:aws:ec2:*:${local.account}:instance/*"
        Condition = { StringEquals = { "ec2:ResourceTag/cnq-path-extender:hub" = local.hub } }
      },
      {
        # Needed when the account encrypts new EBS volumes with a customer managed key.
        Sid      = "ComputeVolumeEncryption"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncrypt*"]
        Resource = "*"
        Condition = {
          StringLike = { "kms:ViaService" = "ec2.*.amazonaws.com" }
        }
      },
      {
        Sid       = "PassComputeInstanceRole"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = "arn:aws:iam::${local.account}:role/${local.hub}-*-compute"
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      {
        # Default AMIs: Amazon Linux 2023, and the Deep Learning AMI for GPU types.
        Sid    = "DefaultComputeAmis"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*",
          "arn:aws:ssm:*::parameter/aws/service/deeplearning/*",
          # Which regions offer PCS (the pcs option).
          "arn:aws:ssm:*::parameter/aws/service/global-infrastructure/*",
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# CodeBuild (runs the spoke stack)
#
# Deploying CNQ needs broad rights: the Qumulo provider creates IAM roles, KMS keys,
# S3 buckets, and EC2 resources. These are the services Qumulo documents as required,
# plus Secrets Manager for the generated spoke credentials, plus tag:GetResources,
# which the provider uses on destroy to find the cluster's S3 buckets (not in
# Qumulo's documented list). The pcs option adds PCS itself, through the Cloud Control
# API (the awscc provider), which also creates PCS's service-linked role on first use.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "codebuild" {
  name = "cnq-path-extender-codebuild-${local.hub}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "deploy-spoke"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DeployCnqSpoke"
      Effect = "Allow"
      Action = [
        "ec2:*",
        "elasticloadbalancing:*",
        "iam:*",
        "kms:*",
        "logs:*",
        "s3:*",
        "secretsmanager:*",
        "ssm:*",
        "sts:*",
        "tag:GetResources",
        "pcs:*",
        "cloudformation:CreateResource",
        "cloudformation:GetResource",
        "cloudformation:UpdateResource",
        "cloudformation:DeleteResource",
        "cloudformation:GetResourceRequestStatus",
        "cloudformation:ListResources",
      ]
      Resource = "*"
    }]
  })
}

# -----------------------------------------------------------------------------
# Step Functions
# -----------------------------------------------------------------------------

resource "aws_iam_role" "sfn" {
  name = "cnq-path-extender-sfn-${local.hub}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "workflows"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.portal.arn, "${aws_lambda_function.portal.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
        Resource = aws_codebuild_project.spoke.arn
      },
      {
        # Used by the .sync integration to wait for the build to finish.
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "arn:aws:events:${var.hub_region}:${local.account}:rule/StepFunctionsGetEventForCodeBuildStartBuildRule"
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.notify.arn
      },
    ]
  })
}
