locals {
  tags = merge(var.tags, {
    Module    = "iam-wildcard-action-policy"
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
  name               = "${var.name_prefix}-iam-wildcard-lambda"
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
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-iam-wildcard-evaluator:*",
    ]
  }

  statement {
    sid    = "IAMReadPolicy"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
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
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

resource "aws_lambda_function" "rule_evaluator" {
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  function_name    = "${var.name_prefix}-iam-wildcard-evaluator"
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
# Config Rule — Custom Lambda detecting <service>:* wildcard actions
# -----------------------------------------------------------------------------

resource "aws_config_config_rule" "this" {
  name = "${var.name_prefix}-iam-wildcard-action-policy"

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
    compliance_resource_types = ["AWS::IAM::Policy"]
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
    sid     = "AllowSSMAssume"
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
  name               = "${var.name_prefix}-iam-wildcard-ssm"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ssm_permissions" {
  # Read policies
  statement {
    sid    = "IAMReadPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy",
      "iam:ListPolicyTags",
      "iam:GetRole",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*",
    ]
  }

  # Tag policies
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

  # Auto-scope (Phase 2)
  statement {
    sid    = "IAMCreatePolicyVersion"
    effect = "Allow"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicyVersion",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }

  # CloudTrail query
  statement {
    sid    = "CloudTrailLookup"
    effect = "Allow"
    actions = [
      "cloudtrail:LookupEvents",
    ]
    resources = ["*"]
  }

  # Service last accessed
  statement {
    sid    = "IAMServiceLastAccessed"
    effect = "Allow"
    actions = [
      "iam:GenerateServiceLastAccessedDetails",
      "iam:GetServiceLastAccessedDetails",
    ]
    resources = ["*"]
  }

  # S3 report (optional)
  statement {
    sid    = "S3WriteReport"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::*/iam-wildcard-reports/*",
    ]
  }
}

resource "aws_iam_role_policy" "ssm_permissions" {
  name   = "ssm-automation-permissions"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_permissions.json
}

# -----------------------------------------------------------------------------
# SSM Automation Document — three-mode detect-and-analyze
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "this" {
  name            = "${var.name_prefix}-iam-wildcard-action-policy"
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
    name         = "CloudTrailLookbackDays"
    static_value = tostring(var.cloudtrail_lookback_days)
  }

  parameter {
    name         = "MinActionsThreshold"
    static_value = tostring(var.min_actions_threshold)
  }

  parameter {
    name         = "ReportS3Bucket"
    static_value = var.report_s3_bucket
  }

  automatic                  = var.automatic_remediation
  maximum_automatic_attempts = var.maximum_automatic_attempts
  retry_attempt_seconds      = var.retry_attempt_seconds
}
