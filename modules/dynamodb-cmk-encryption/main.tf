################################################################################
# Locals
################################################################################

locals {
  tags = merge(var.tags, {
    Module    = "dynamodb-cmk-encryption"
    ManagedBy = "Terraform"
    Purpose   = "crwd-remediator"
  })

  effective_kms_key_arn = var.create_kms_key ? aws_kms_key.dynamodb[0].arn : var.kms_key_arn
  effective_kms_key_id  = var.create_kms_key ? aws_kms_key.dynamodb[0].key_id : element(split("/", var.kms_key_arn), length(split("/", var.kms_key_arn)) - 1)
}

################################################################################
# KMS Key (optionally created by the module)
################################################################################

resource "aws_kms_key" "dynamodb" {
  count               = var.create_kms_key ? 1 : 0
  description         = "Customer-managed key for DynamoDB table encryption (crwd-remediators)"
  enable_key_rotation = true
  tags                = local.tags

  policy = data.aws_iam_policy_document.kms_key_policy[0].json
}

resource "aws_kms_alias" "dynamodb" {
  count         = var.create_kms_key ? 1 : 0
  name          = "alias/${var.name_prefix}-dynamodb-cmk"
  target_key_id = aws_kms_key.dynamodb[0].key_id
}

data "aws_iam_policy_document" "kms_key_policy" {
  count = var.create_kms_key ? 1 : 0

  statement {
    sid    = "EnableRootAccountAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSSMAutomationRole"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ssm_automation.arn]
    }
    actions = [
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowDynamoDBService"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["dynamodb.amazonaws.com"]
    }
    actions = [
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:CreateGrant",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

################################################################################
# 1. Config Rule — detection
################################################################################

resource "aws_config_config_rule" "this" {
  name = "${var.name_prefix}-dynamodb-cmk-encryption"

  source {
    owner             = "AWS"
    source_identifier = "DYNAMODB_TABLE_ENCRYPTED_KMS"
  }

  scope {
    compliance_resource_types = ["AWS::DynamoDB::Table"]
  }

  input_parameters = length(var.config_rule_input_parameters) > 0 ? jsonencode(var.config_rule_input_parameters) : null

  tags = local.tags
}

################################################################################
# 2. IAM Role — SSM Automation assume role
################################################################################

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
  name               = "${var.name_prefix}-dynamodb-cmk-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ssm_remediation" {
  statement {
    sid    = "DynamoDBAccess"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:UpdateTable",
      "dynamodb:ListTagsOfResource",
      "dynamodb:TagResource",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/*",
    ]
  }

  statement {
    sid    = "KMSAccess"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*",
    ]
  }
}

resource "aws_iam_role_policy" "ssm_remediation" {
  name   = "${var.name_prefix}-dynamodb-cmk-remediation"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_remediation.json
}

################################################################################
# 3. SSM Document — Tier 1 custom wrapper (always created)
################################################################################

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-dynamodb-cmk-encryption"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/ssm/document.yaml")
  tags            = local.tags
}

################################################################################
# 4. Config Remediation Configuration — the wire
################################################################################

resource "aws_config_remediation_configuration" "this" {
  config_rule_name = aws_config_config_rule.this.name
  target_type      = "SSM_DOCUMENT"
  target_id        = aws_ssm_document.this.name
  resource_type    = "AWS::DynamoDB::Table"

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.automatic_remediation ? var.maximum_automatic_attempts : null
  retry_attempt_seconds      = var.automatic_remediation ? var.retry_attempt_seconds : null

  parameter {
    name           = "TableName"
    resource_value = "RESOURCE_ID"
  }

  parameter {
    name         = "Action"
    static_value = "assess"
  }

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.ssm_automation.arn
  }

  parameter {
    name         = "KmsKeyArn"
    static_value = local.effective_kms_key_arn
  }

  parameter {
    name          = "ExcludedResourceIds"
    static_values = var.excluded_resource_ids
  }

  parameter {
    name         = "AssessmentTagKey"
    static_value = var.assessment_tag_key
  }

  parameter {
    name         = "Partition"
    static_value = data.aws_partition.current.partition
  }
}
