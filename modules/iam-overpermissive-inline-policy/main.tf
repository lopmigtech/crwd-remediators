locals {
  tags = merge(var.tags, {
    Module    = "iam-overpermissive-inline-policy"
    ManagedBy = "Terraform"
    Purpose   = "crwd-remediator"
  })
}

# -----------------------------------------------------------------------------
# Lambda Config Rule Evaluator — IAM role and function
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "AllowLambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "lambda_config_rule" {
  name               = "${var.name_prefix}-iam-overpermissive-inline-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-iam-overpermissive-inline-evaluator:*",
    ]
  }

  statement {
    sid    = "ConfigPutEvaluations"
    effect = "Allow"
    actions = [
      "config:PutEvaluations",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "lambda-config-rule-permissions"
  role   = aws_iam_role.lambda_config_rule.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda/handler.zip"

  source {
    content  = file("${path.module}/lambda/handler.py")
    filename = "handler.py"
  }
  source {
    content  = file("${path.module}/lambda/evaluator.py")
    filename = "evaluator.py"
  }
  source {
    content  = file("${path.module}/lambda/patterns.py")
    filename = "patterns.py"
  }
  source {
    content  = file("${path.module}/lambda/resource_ids.py")
    filename = "resource_ids.py"
  }
}

resource "aws_lambda_function" "rule_evaluator" {
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  function_name    = "${var.name_prefix}-iam-overpermissive-inline-evaluator"
  role             = aws_iam_role.lambda_config_rule.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 128

  tags = local.tags
}

resource "aws_lambda_permission" "config_invoke" {
  statement_id   = "AllowConfigInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rule_evaluator.function_name
  principal      = "config.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# -----------------------------------------------------------------------------
# Config Rule — Custom Lambda detecting inline policy wildcards on principals
# -----------------------------------------------------------------------------

resource "aws_config_config_rule" "this" {
  name = "${var.name_prefix}-iam-overpermissive-inline-policy"

  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.rule_evaluator.arn

    source_detail {
      message_type = "ConfigurationItemChangeNotification"
    }
    source_detail {
      message_type = "OversizedConfigurationItemChangeNotification"
    }

    dynamic "source_detail" {
      for_each = var.evaluation_frequency == "Off" ? [] : [1]
      content {
        message_type                = "ScheduledNotification"
        maximum_execution_frequency = var.evaluation_frequency
      }
    }
  }

  scope {
    compliance_resource_types = [
      "AWS::IAM::Role",
      "AWS::IAM::User",
      "AWS::IAM::Group",
    ]
  }

  input_parameters = length(var.config_rule_input_parameters) > 0 ? jsonencode(var.config_rule_input_parameters) : null

  depends_on = [aws_lambda_permission.config_invoke]

  tags = local.tags
}

# -----------------------------------------------------------------------------
# SSM Automation Role — used by the SSM document for remediation
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
  name               = "${var.name_prefix}-iam-overpermissive-inline-ssm"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ssm_permissions" {
  # List principals — required to resolve Config's RESOURCE_ID (AWS resource ID) to a principal name.
  # Account-level APIs; do not support resource-level permissions.
  statement {
    sid    = "IAMListPrincipals"
    effect = "Allow"
    actions = [
      "iam:ListRoles",
      "iam:ListUsers",
      "iam:ListGroups",
    ]
    resources = ["*"]
  }

  # Read principal metadata
  statement {
    sid    = "IAMReadPrincipals"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetUser",
      "iam:GetGroup",
      "iam:ListRoleTags",
      "iam:ListUserTags",
      "iam:ListGroupTags",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:group/*",
    ]
  }

  # Read inline policies attached to principals
  statement {
    sid    = "IAMReadInlinePolicies"
    effect = "Allow"
    actions = [
      "iam:ListRolePolicies",
      "iam:ListUserPolicies",
      "iam:ListGroupPolicies",
      "iam:GetRolePolicy",
      "iam:GetUserPolicy",
      "iam:GetGroupPolicy",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:group/*",
    ]
  }

  # Tag principals with analyze findings
  statement {
    sid    = "IAMTagPrincipals"
    effect = "Allow"
    actions = [
      "iam:TagRole",
      "iam:TagUser",
      "iam:TagGroup",
      "iam:UntagRole",
      "iam:UntagUser",
      "iam:UntagGroup",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:group/*",
    ]
  }
}

resource "aws_iam_role_policy" "ssm_permissions" {
  name   = "ssm-automation-permissions"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_permissions.json
}

# -----------------------------------------------------------------------------
# SSM Automation Document — analyze-mode placeholder (full logic in next release)
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-iam-overpermissive-inline-policy"
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

  parameter {
    name         = "EnableRoleRemediation"
    static_value = var.enable_role_remediation ? "true" : "false"
  }

  parameter {
    name         = "EnableUserRemediation"
    static_value = var.enable_user_remediation ? "true" : "false"
  }

  parameter {
    name         = "EnableGroupRemediation"
    static_value = var.enable_group_remediation ? "true" : "false"
  }

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.maximum_automatic_attempts
  retry_attempt_seconds      = var.retry_attempt_seconds
}
