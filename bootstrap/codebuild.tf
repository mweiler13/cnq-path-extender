# The spoke stack is bundled from this copy of the code and uploaded on every apply.
# No repository connection: to change what spokes run, edit spoke/ and re-apply here.
data "archive_file" "spoke" {
  type        = "zip"
  source_dir  = "${path.module}/../spoke"
  output_path = "${path.module}/build/spoke.zip"
  # Local working files that must never ship (provider caches, real tfvars, local state).
  excludes = [
    "**/.terraform/**", "**/terraform.tfvars", "**/*.tfstate", "**/*.tfstate.*",
    "**/__pycache__/**", "**/*.pyc",
  ]
}

locals {
  build_timeout_minutes = 180
}

resource "aws_s3_object" "spoke_bundle" {
  bucket      = var.state_bucket
  key         = "${local.hub}/bundle/spoke.zip"
  source      = data.archive_file.spoke.output_path
  source_hash = data.archive_file.spoke.output_base64sha256
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/spoke-build-${local.hub}"
  retention_in_days = 30
}

resource "aws_codebuild_project" "spoke" {
  name          = "spoke-build-${local.hub}"
  description   = "Runs terraform apply/destroy for spokes of hub ${local.hub}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = local.build_timeout_minutes

  source {
    type      = "S3"
    location  = "${var.state_bucket}/${aws_s3_object.spoke_bundle.key}"
    buildspec = file("${path.module}/buildspec.yml")
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # Fixed for every spoke of this hub. Per-launch values are added by the workflows.
    dynamic "environment_variable" {
      for_each = {
        TF_VERSION                    = var.terraform_version
        TF_LOCK_STALE_MINUTES         = tostring(local.build_timeout_minutes + 10)
        TF_STATE_BUCKET               = var.state_bucket
        TF_STATE_REGION               = var.hub_region
        TF_VAR_hub_name               = local.hub
        TF_VAR_hub_region             = var.hub_region
        TF_VAR_hub_vpc_id             = data.aws_vpc.hub.id
        TF_VAR_hub_vpc_cidr           = data.aws_vpc.hub.cidr_block
        TF_VAR_hub_route_table_ids    = jsonencode(local.hub_route_table_ids)
        TF_VAR_cdf_security_group_id  = aws_security_group.cdf.id
        TF_VAR_soft_capacity_limit_tb = tostring(var.spoke_capacity_tb)
        TF_VAR_cluster_product_type   = var.spoke_product_type
        TF_VAR_extra_tags             = jsonencode(var.extra_tags)
      }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }
}
