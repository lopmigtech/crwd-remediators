locals {
  tags = merge(var.tags, {
    Module    = "s3-access-logging"
    ManagedBy = "Terraform"
    Purpose   = "crwd-remediator"
  })
}

# -------------------------------------------------------
# 1. Config Rule — S3_BUCKET_LOGGING_ENABLED (managed)
# -------------------------------------------------------

resource "aws_config_config_rule" "this" {
  name             = "${var.name_prefix}-s3-access-logging"
  description      = "Checks whether S3 buckets have server access logging enabled."
  input_parameters = length(var.config_rule_input_parameters) > 0 ? jsonencode(var.config_rule_input_parameters) : null

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LOGGING_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  tags = local.tags
}

# -------------------------------------------------------
# 2. IAM Role — SSM Automation assume role
# -------------------------------------------------------

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

resource "aws_iam_role" "ssm_automation" {
  name               = "${var.name_prefix}-s3-access-logging-ssm"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ssm_remediation" {
  # S3 permissions for the actual remediation
  statement {
    sid    = "AllowS3LoggingRemediation"
    effect = "Allow"
    actions = [
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetBucketAcl",
      "s3:PutBucketAcl",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::*",
    ]
  }

  # NOTE: No SSM execution or IAM PassRole permissions needed here.
  # The custom SSM doc uses aws:executeAwsApi (direct S3 API call)
  # instead of aws:executeAutomation (nested SSM doc delegation).
  # This is simpler and avoids the ACL-incompatibility issue with
  # the AWS managed AWS-ConfigureS3BucketLogging document.
}

resource "aws_iam_role_policy" "ssm_remediation" {
  name   = "${var.name_prefix}-s3-access-logging-remediation"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_remediation.json
}

# -------------------------------------------------------
# 3. SSM Automation Document — Tier 1 custom wrapper
# -------------------------------------------------------

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-s3-access-logging"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/ssm/document.yaml")
  tags            = local.tags
}

# -------------------------------------------------------
# 4. Config Remediation Configuration — the wire
# -------------------------------------------------------

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

  # NOTE: GrantedPermission, GranteeType, GranteeUri parameters are intentionally
  # OMITTED. Modern S3 buckets (created after April 2023) use "Bucket Owner
  # Enforced" object ownership which disables ACLs. The AWS managed SSM doc
  # falls back to the bucket-policy-based approach when grantee params are absent.
  # The destination bucket must have a policy allowing logging.s3.amazonaws.com
  # to s3:PutObject (set up separately, not managed by this module).

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
    static_value = jsonencode(var.excluded_resource_ids)
  }

  parameter {
    name         = "LogDestinationBucket"
    static_value = var.log_destination_bucket
  }

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.maximum_automatic_attempts
  retry_attempt_seconds      = var.retry_attempt_seconds
}
