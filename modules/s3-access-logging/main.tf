locals {
  tags = merge(var.tags, {
    Module    = "s3-access-logging"
    ManagedBy = "Terraform"
    Purpose   = "crwd-remediator"
  })
}

resource "aws_config_config_rule" "this" {
  name = "${var.name_prefix}-s3-access-logging"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LOGGING_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  input_parameters = length(var.config_rule_input_parameters) > 0 ? jsonencode(var.config_rule_input_parameters) : null

  tags = local.tags
}

data "aws_iam_policy_document" "ssm_assume_role" {
  statement {
    sid     = "AllowSSMAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "ssm_remediation_permissions" {
  statement {
    sid    = "AllowS3LoggingOperations"
    effect = "Allow"
    actions = [
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetBucketAcl",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::*",
    ]
  }
}

resource "aws_iam_role" "ssm_automation" {
  name               = "${var.name_prefix}-s3-access-logging-ssm"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy" "ssm_remediation_permissions" {
  name   = "s3-access-logging-remediation"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_remediation_permissions.json
}

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-s3-access-logging"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/ssm/document.yaml")

  tags = local.tags
}

resource "aws_config_remediation_configuration" "this" {
  config_rule_name = aws_config_config_rule.this.name
  target_type      = "SSM_DOCUMENT"
  target_id        = aws_ssm_document.this.name
  resource_type    = "AWS::S3::Bucket"

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.ssm_automation.arn
  }

  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }

  parameter {
    name         = "TargetBucket"
    static_value = var.log_destination_bucket
  }

  parameter {
    name         = "TargetPrefix"
    static_value = var.log_destination_prefix
  }

  parameter {
    name         = "ExcludedResourceIds"
    static_value = length(var.excluded_resource_ids) > 0 ? join(",", var.excluded_resource_ids) : " "
  }

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.maximum_automatic_attempts
  retry_attempt_seconds      = var.retry_attempt_seconds

  execution_controls {
    ssm_controls {
      concurrent_execution_rate_percentage = 10
      error_percentage                     = 10
    }
  }
}
