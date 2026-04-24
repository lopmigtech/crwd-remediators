provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  prefix     = "crwd-test"
}

# =============================================================================
# AWS Config Prerequisites
# =============================================================================

resource "aws_s3_bucket" "config" {
  bucket        = "${local.prefix}-config-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config.arn
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config.arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "config" {
  name = "${local.prefix}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  name     = "${local.prefix}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${local.prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# =============================================================================
# The Module Under Test — v1.1.0 with analyze mode (Phase 1)
# =============================================================================

module "iam_wildcard_action_policy" {
  source = "../../modules/iam-wildcard-action-policy"

  name_prefix           = local.prefix
  automatic_remediation = true
  remediation_action    = "analyze"
  evaluation_frequency  = "TwentyFour_Hours"

  tag_based_exemption_enabled = true
  require_exemption_reason    = true

  # C1 e2e test: list-exclusion path. The policy ARN is added here, but Config will
  # send the policy UUID via RESOURCE_ID. The SSM doc's resolver converts the UUID
  # back to an ARN and the list-membership check matches on either form.
  excluded_resource_ids = [aws_iam_policy.list_excluded.arn]

  tags = {
    Environment = "test"
    Project     = "crwd-remediators-live-test"
  }

  depends_on = [aws_config_configuration_recorder_status.this]
}

# =============================================================================
# Test IAM Policies — simulating your 30 offending patterns
# =============================================================================

# --- Simple policies (1 wildcard service each) ---

resource "aws_iam_policy" "simple_artifact" {
  name   = "${local.prefix}-simple-artifact"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["artifact:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_securityhub" {
  name   = "${local.prefix}-simple-securityhub"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["securityhub:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_wafv2" {
  name   = "${local.prefix}-simple-wafv2"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["wafv2:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_acm" {
  name   = "${local.prefix}-simple-acm"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["acm:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_cloudtrail" {
  name   = "${local.prefix}-simple-cloudtrail"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["cloudtrail:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_directconnect" {
  name   = "${local.prefix}-simple-directconnect"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["directconnect:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_elasticache" {
  name   = "${local.prefix}-simple-elasticache"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["elasticache:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_ram" {
  name   = "${local.prefix}-simple-ram"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ram:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_cloudwatch" {
  name   = "${local.prefix}-simple-cloudwatch"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["cloudwatch:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_dynamodb" {
  name   = "${local.prefix}-simple-dynamodb"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["dynamodb:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_glue" {
  name   = "${local.prefix}-simple-glue"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["glue:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_aoss" {
  name   = "${local.prefix}-simple-aoss"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["aoss:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_kendra" {
  name   = "${local.prefix}-simple-kendra"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["kendra:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_imagebuilder" {
  name   = "${local.prefix}-simple-imagebuilder"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["imagebuilder:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_transfer" {
  name   = "${local.prefix}-simple-transfer"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["transfer:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "simple_access_analyzer" {
  name   = "${local.prefix}-simple-access-analyzer"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["access-analyzer:*"], Resource = "*" }] })
}

# --- Moderate policies (2-3 wildcard services) ---

resource "aws_iam_policy" "moderate_network" {
  name   = "${local.prefix}-moderate-network"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ec2:*", "route53:*", "route53resolver:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "moderate_data" {
  name   = "${local.prefix}-moderate-data"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["rds:*", "elasticache:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "moderate_serverless" {
  name   = "${local.prefix}-moderate-serverless"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["lambda:*", "sns:*", "sqs:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "moderate_observability" {
  name   = "${local.prefix}-moderate-observability"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:*", "cloudwatch:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "moderate_storage" {
  name   = "${local.prefix}-moderate-storage"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["elasticfilesystem:*", "transfer:*"], Resource = "*" }] })
}

# --- Complex policies (4+ wildcard services) ---

resource "aws_iam_policy" "complex_analytics" {
  name   = "${local.prefix}-complex-analytics"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["glue:*", "aoss:*", "kendra:*", "es:*", "kafka-cluster:*"], Resource = "*" }] })
}

resource "aws_iam_policy" "complex_infra" {
  name   = "${local.prefix}-complex-infra"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ec2:*", "autoscaling:*", "elasticloadbalancing:*", "route53:*", "elasticmapreduce:*"], Resource = "*" }] })
}

# --- Compliant policy (no wildcards — should pass) ---

resource "aws_iam_policy" "compliant" {
  name   = "${local.prefix}-compliant"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket", "logs:CreateLogGroup"], Resource = "*" }] })
}

# --- Exclusion/exemption test cases ---

# List-based exclusion: referenced by the module's excluded_resource_ids input.
# Expected: Config flags NON_COMPLIANT; SSM CheckExclusion skips with "in the exclusion list".
resource "aws_iam_policy" "list_excluded" {
  name   = "${local.prefix}-excl-list"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["sagemaker:*"], Resource = "*" }] })
}

# Tag-exempt (with reason): CrwdRemediatorExempt=true + non-empty reason tag.
# Expected: Config flags NON_COMPLIANT; SSM CheckExclusion skips with the reason.
resource "aws_iam_policy" "tag_exempt" {
  name   = "${local.prefix}-excl-tag"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["polly:*"], Resource = "*" }] })
  tags = {
    CrwdRemediatorExempt       = "true"
    CrwdRemediatorExemptReason = "e2e-test: legit break-glass policy example"
  }
}

# Tag-exempt WITHOUT reason: require_exemption_reason=true → should NOT be exempt.
# Expected: Config flags NON_COMPLIANT; SSM CheckExclusion logs WARN + proceeds with
# remediation (tag ignored because reason tag is empty).
resource "aws_iam_policy" "tag_exempt_no_reason" {
  name   = "${local.prefix}-excl-tag-noreason"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["comprehend:*"], Resource = "*" }] })
  tags = {
    CrwdRemediatorExempt = "true"
    # Intentionally no CrwdRemediatorExemptReason
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "config_rule_name" {
  value = module.iam_wildcard_action_policy.config_rule_name
}

output "ssm_document_name" {
  value = module.iam_wildcard_action_policy.ssm_document_name
}

output "iam_role_arn" {
  value = module.iam_wildcard_action_policy.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  value = module.iam_wildcard_action_policy.non_compliant_resources_cli_command
}

# Exposed so e2e verification can look up the UUID Config sees for each test policy.
output "test_policy_ids" {
  value = {
    simple_artifact      = aws_iam_policy.simple_artifact.policy_id
    moderate_network     = aws_iam_policy.moderate_network.policy_id
    complex_analytics    = aws_iam_policy.complex_analytics.policy_id
    compliant            = aws_iam_policy.compliant.policy_id
    list_excluded        = aws_iam_policy.list_excluded.policy_id
    tag_exempt           = aws_iam_policy.tag_exempt.policy_id
    tag_exempt_no_reason = aws_iam_policy.tag_exempt_no_reason.policy_id
  }
}

output "test_policy_arns" {
  value = {
    simple_artifact      = aws_iam_policy.simple_artifact.arn
    moderate_network     = aws_iam_policy.moderate_network.arn
    complex_analytics    = aws_iam_policy.complex_analytics.arn
    compliant            = aws_iam_policy.compliant.arn
    list_excluded        = aws_iam_policy.list_excluded.arn
    tag_exempt           = aws_iam_policy.tag_exempt.arn
    tag_exempt_no_reason = aws_iam_policy.tag_exempt_no_reason.arn
  }
}
