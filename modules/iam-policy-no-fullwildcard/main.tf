locals {
  tags = merge(var.tags, {
    Module    = "iam-policy-no-fullwildcard"
    ManagedBy = "Terraform"
    Purpose   = "crwd-remediator"
  })
}

# -----------------------------------------------------------------------------
# Config Rule — AWS-managed, detects Action:"*" + Resource:"*" combinations
# in customer-managed policies (per Rule 10: prefer AWS-managed rules).
# -----------------------------------------------------------------------------

resource "aws_config_config_rule" "this" {
  name = "${var.name_prefix}-iam-policy-no-fullwildcard"

  source {
    owner             = "AWS"
    source_identifier = "IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::Policy"]
  }

  input_parameters = length(var.config_rule_input_parameters) > 0 ? jsonencode(var.config_rule_input_parameters) : null

  tags = local.tags
}

# -----------------------------------------------------------------------------
# SSM Automation Role — used by the SSM document for tag-and-route remediation
# -----------------------------------------------------------------------------

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
  name               = "${var.name_prefix}-iam-policy-no-fullwildcard-ssm"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ssm_permissions" {
  # List policies — required to resolve Config's RESOURCE_ID (policy UUID) to an ARN.
  # Account-level API; does not support resource-level permissions.
  statement {
    sid    = "IAMListPolicies"
    effect = "Allow"
    actions = [
      "iam:ListPolicies",
    ]
    resources = ["*"]
  }

  # Read policy metadata + tags (for exemption checks)
  statement {
    sid    = "IAMReadPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyTags",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }

  # Tag policies with severity findings
  statement {
    sid    = "IAMTagPolicies"
    effect = "Allow"
    actions = [
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }
}

resource "aws_iam_role_policy" "ssm_permissions" {
  name   = "ssm-automation-permissions"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_permissions.json
}

# -----------------------------------------------------------------------------
# SSM Automation Document — tag-and-route mode
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-iam-policy-no-fullwildcard"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/ssm/document.yaml")
  tags            = local.tags
}

# -----------------------------------------------------------------------------
# Config Remediation Configuration — wires the Config rule to the SSM doc
# -----------------------------------------------------------------------------

resource "aws_config_remediation_configuration" "this" {
  config_rule_name = aws_config_config_rule.this.name
  target_type      = "SSM_DOCUMENT"
  target_id        = aws_ssm_document.this.name
  resource_type    = "AWS::IAM::Policy"

  parameter {
    name           = "ResourceId"
    resource_value = "RESOURCE_ID"
  }

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.ssm_automation.arn
  }

  parameter {
    name          = "ExcludedResourceIds"
    static_values = var.excluded_resource_ids
  }

  parameter {
    name         = "Action"
    static_value = var.remediation_action
  }

  parameter {
    name         = "TagBasedExemptionEnabled"
    static_value = var.tag_based_exemption_enabled ? "true" : "false"
  }

  parameter {
    name         = "ExemptionTagKey"
    static_value = var.exemption_tag_key
  }

  parameter {
    name         = "RequireExemptionReason"
    static_value = var.require_exemption_reason ? "true" : "false"
  }

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.maximum_automatic_attempts
  retry_attempt_seconds      = var.retry_attempt_seconds
}
