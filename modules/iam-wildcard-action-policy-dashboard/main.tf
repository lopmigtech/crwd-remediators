locals {
  resource_prefix = "${var.name_prefix}-iam-wildcard-dashboard"
  bucket_name     = "${local.resource_prefix}-${data.aws_caller_identity.current.account_id}"
  bucket_arn      = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"
}

# -----------------------------------------------------------------------------
# S3 bucket — hosts the rendered dashboard.html. Private, encrypted, versioned.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "dashboard" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "dashboard_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      local.bucket_arn,
      "${local.bucket_arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  policy = data.aws_iam_policy_document.dashboard_bucket.json
}

resource "aws_s3_bucket_logging" "dashboard" {
  count = var.access_log_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.dashboard.id
  target_bucket = var.access_log_bucket
  target_prefix = "${local.resource_prefix}/"
}

# -----------------------------------------------------------------------------
# Refresh Lambda — scheduled, read-only, renders dashboard.html to S3
# -----------------------------------------------------------------------------

data "archive_file" "refresh" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/refresh"
  output_path = "${path.module}/build/refresh.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

data "aws_iam_policy_document" "refresh_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "refresh" {
  name               = "${local.resource_prefix}-refresh"
  assume_role_policy = data.aws_iam_policy_document.refresh_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "refresh" {
  statement {
    sid    = "ReadConfigComplianceDetails"
    effect = "Allow"
    actions = [
      "config:GetComplianceDetailsByConfigRule",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:config:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:config-rule/${var.config_rule_name}",
    ]
  }

  statement {
    sid     = "ListIAMPolicies"
    effect  = "Allow"
    actions = ["iam:ListPolicies"]
    # iam:ListPolicies does not support resource-level permissions; AWS requires "*".
    resources = ["*"]
  }

  statement {
    sid     = "ReadIAMPolicyTags"
    effect  = "Allow"
    actions = ["iam:ListPolicyTags"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }

  statement {
    sid       = "GetCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"] # AWS does not support resource-level perms for this action.
  }

  statement {
    sid       = "WriteDashboardObject"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/dashboard.html"]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}-refresh:*",
    ]
  }
}

resource "aws_iam_role_policy" "refresh" {
  name   = "${local.resource_prefix}-refresh"
  role   = aws_iam_role.refresh.id
  policy = data.aws_iam_policy_document.refresh.json
}

resource "aws_lambda_function" "refresh" {
  function_name    = "${local.resource_prefix}-refresh"
  filename         = data.archive_file.refresh.output_path
  source_code_hash = data.archive_file.refresh.output_base64sha256
  role             = aws_iam_role.refresh.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 512
  timeout          = 300

  environment {
    variables = {
      CONFIG_RULE_NAME      = var.config_rule_name
      DASHBOARD_BUCKET      = aws_s3_bucket.dashboard.id
      EXCLUDED_RESOURCE_IDS = join(",", var.excluded_resource_ids)
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Redirect Lambda — fronted by Function URL with AWS_IAM auth
# -----------------------------------------------------------------------------

data "archive_file" "redirect" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/redirect"
  output_path = "${path.module}/build/redirect.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

resource "aws_iam_role" "redirect" {
  name               = "${local.resource_prefix}-redirect"
  assume_role_policy = data.aws_iam_policy_document.refresh_assume_role.json # same trust
  tags               = var.tags
}

data "aws_iam_policy_document" "redirect" {
  statement {
    sid       = "ReadDashboardObject"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/dashboard.html"]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}-redirect:*",
    ]
  }
}

resource "aws_iam_role_policy" "redirect" {
  name   = "${local.resource_prefix}-redirect"
  role   = aws_iam_role.redirect.id
  policy = data.aws_iam_policy_document.redirect.json
}

resource "aws_lambda_function" "redirect" {
  function_name    = "${local.resource_prefix}-redirect"
  filename         = data.archive_file.redirect.output_path
  source_code_hash = data.archive_file.redirect.output_base64sha256
  role             = aws_iam_role.redirect.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      DASHBOARD_BUCKET      = aws_s3_bucket.dashboard.id
      PRESIGNED_TTL_SECONDS = tostring(var.presigned_url_ttl_seconds)
    }
  }

  tags = var.tags
}

resource "aws_lambda_function_url" "redirect" {
  function_name      = aws_lambda_function.redirect.function_name
  authorization_type = "AWS_IAM"
}

# -----------------------------------------------------------------------------
# EventBridge schedule — invokes the refresh Lambda every N minutes
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "refresh_schedule" {
  name                = "${local.resource_prefix}-schedule"
  description         = "Periodically invoke the iam-wildcard-action-policy dashboard refresh Lambda"
  schedule_expression = "rate(${var.refresh_schedule_minutes} minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "refresh_schedule" {
  rule      = aws_cloudwatch_event_rule.refresh_schedule.name
  target_id = "refresh-lambda"
  arn       = aws_lambda_function.refresh.arn
}

resource "aws_lambda_permission" "refresh_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.refresh.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.refresh_schedule.arn
}
