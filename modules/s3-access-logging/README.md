# s3-access-logging

Detects S3 buckets without server access logging enabled and remediates by configuring logging to a centralized destination bucket.

**Proactive hardening — no finding mapped yet**

**GovCloud compatibility:** both partitions

## Prerequisites

AWS Config must be enabled in the target account and recording all supported resource types. Verify with:

```bash
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
```

Expected output: `true`. If `false`, enable Config before deploying this module.

## Usage

```hcl
module "s3_access_logging" {
  source = "git::https://gitlab.com/<owner>/crwd-remediators.git//modules/s3-access-logging?ref=s3-access-logging/v1.0.0"

  name_prefix            = "myorg"
  log_destination_bucket = "myorg-s3-access-logs"
  log_destination_prefix = "s3-logs/"
}
```

## Safety defaults

This module deploys with `automatic_remediation = false` (dry-run). After deploy, Config will identify non-compliant resources but SSM will NOT run remediation automatically. To see the current non-compliance list, run the command from `terraform output non_compliant_resources_cli_command`. Once you have reviewed the list and are confident the remediation is safe, flip `automatic_remediation = true` in your Terraform and re-apply.

## How to test this module

1. Create a non-compliant test S3 bucket (one without server access logging enabled)
2. Force a Config evaluation: `aws configservice start-config-rules-evaluation --config-rule-names <rule-name>`
3. Verify the Config rule marks the bucket as NON_COMPLIANT: `aws configservice get-compliance-details-by-config-rule --config-rule-name <rule-name>`
4. Manually trigger the SSM document against the non-compliant bucket: `aws ssm start-automation-execution --document-name <doc-name> --parameters '{"BucketName":["my-test-bucket"],"AutomationAssumeRole":["<role-arn>"],"TargetBucket":["my-logs-bucket"],"TargetPrefix":["test/"],"LogDestinationBucket":["my-logs-bucket"],"ExcludedResourceIds":["[]"],"GrantedPermission":["WRITE"],"GranteeType":["Group"],"GranteeUri":["http://acs.amazonaws.com/groups/s3/LogDelivery"]}'`
5. Verify the bucket now has server access logging enabled: `aws s3api get-bucket-logging --bucket my-test-bucket`
6. Optionally flip `automatic_remediation = true` in Terraform, re-apply, and verify automatic remediation

## Per-resource exclusion (Tier 1)

This module ships a custom SSM Automation document that honors exclusions at the document level. Two types of exclusions are enforced:

### Inherent exclusions

The **log destination bucket** (`log_destination_bucket`) is automatically excluded from remediation. Enabling access logging on the bucket that receives logs would create an infinite feedback loop of log deliveries that grows exponentially and can explode storage costs. This exclusion is computed from the module's own inputs — no operator action is required.

### Operational exclusions

Add bucket names to `excluded_resource_ids` to exempt them from remediation:

```hcl
module "s3_access_logging" {
  source = "../../"

  name_prefix            = "myorg"
  log_destination_bucket = "myorg-s3-access-logs"
  excluded_resource_ids  = ["legacy-bucket-do-not-touch", "shared-bucket-managed-elsewhere"]
}
```

Both inherent and operational exclusions are checked before remediation proceeds. If a bucket matches either list, the SSM execution exits cleanly without modifying the bucket.

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
