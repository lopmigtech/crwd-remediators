# s3-access-logging

Detects S3 buckets missing server access logging and remediates them by enabling logging to a central destination bucket.

**Proactive hardening — no finding mapped yet**

**GovCloud compatibility:** both partitions

## Usage

```hcl
module "s3_access_logging" {
  source = "git::https://gitlab.com/lopmig.tech/crwd-remediators.git//modules/s3-access-logging?ref=s3-access-logging/v1.0.1"

  name_prefix            = "my-project"
  log_destination_bucket = "my-central-logging-bucket"
}
```

See the [Quick Start](#quick-start-deployment-guide) section below for a full walkthrough, and the [Inputs Reference](#inputs-reference) for all available variables.

## Architecture

This module deploys four AWS resources and wires them together into a detect-and-remediate loop:

```
AWS Config rule (S3_BUCKET_LOGGING_ENABLED)
    │
    │  detects non-compliant buckets at periodic evaluation intervals
    ▼
Config remediation configuration
    │
    │  passes non-compliant bucket name + parameters to SSM
    ▼
SSM Automation document (custom wrapper)
    │
    ├─ Step 1: CheckExclusion
    │     • Inherent: skip if bucket == log_destination_bucket (avoids infinite loop)
    │     • Operational: skip if bucket is in excluded_resource_ids
    │
    ├─ Step 2: BranchOnExclusion
    │     • "skip" → ExitSkipped (no-op, clean exit)
    │     • "remediate" → InvokeRemediation
    │
    └─ Step 3: InvokeRemediation
          • Calls S3 PutBucketLogging API directly
          • Sets TargetBucket + TargetPrefix from module inputs
          ▼
    Bucket is now compliant — Config re-evaluates as COMPLIANT
```

**Why a custom SSM document instead of the AWS managed `AWS-ConfigureS3BucketLogging`?**
The managed document uses ACL-based approaches that fail on buckets with Bucket Owner Enforced (the S3 default since April 2023). The custom wrapper calls `PutBucketLogging` directly, which is compatible with all modern bucket configurations, needs fewer IAM permissions, and gives us full control over the exclusion logic.

## Prerequisites

Before deploying this module, confirm all of the following:

1. **AWS Config is enabled** and recording all supported resource types:
   ```bash
   aws configservice describe-configuration-recorders \
     --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
   ```
   Expected output: `true`. If `false`, enable Config before deploying.

2. **The log destination bucket already exists.** This module does NOT create it. Verify:
   ```bash
   aws s3api head-bucket --bucket YOUR_DESTINATION_BUCKET
   ```

3. **The log destination bucket has the correct bucket policy** allowing the S3 logging service to write objects. The policy must grant `s3:PutObject` to `logging.s3.amazonaws.com`:
   ```json
   {
     "Effect": "Allow",
     "Principal": { "Service": "logging.s3.amazonaws.com" },
     "Action": "s3:PutObject",
     "Resource": "arn:aws:s3:::YOUR_DESTINATION_BUCKET/*",
     "Condition": {
       "StringEquals": {
         "aws:SourceAccount": "YOUR_ACCOUNT_ID"
       }
     }
   }
   ```
   Ask your platform team to confirm this policy is in place before deploying.

4. **Terraform >= 1.6.0** is installed:
   ```bash
   terraform version
   ```

5. **Your IAM identity has permissions** to create Config rules, IAM roles, SSM documents, and Config remediation configurations. Typically a security-tooling or admin role.

## Quick Start (Deployment Guide)

1. **Copy the example directory** to your working directory:
   ```bash
   cp -r examples/basic my-s3-access-logging
   cd my-s3-access-logging
   ```

2. **Copy the tfvars template:**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. **Edit `terraform.tfvars`** with your values. At minimum you must set:
   - `name_prefix` — a short identifier for your project or team
   - `log_destination_bucket` — the bucket that will receive access logs

4. **Initialize Terraform:**
   ```bash
   terraform init
   ```

5. **Review the plan** — understand what will be created before applying:
   ```bash
   terraform plan
   ```
   You should see 4 resources: one Config rule, one IAM role, one SSM document, and one remediation configuration.

6. **Apply:**
   ```bash
   terraform apply
   ```

7. **See which buckets are non-compliant.** After Config evaluates (can take up to a few minutes after the first deploy), run:
   ```bash
   terraform output non_compliant_resources_cli_command
   ```
   Copy and run the printed command. It will list all S3 buckets currently flagged as non-compliant.

8. **Review the list carefully.** When you are satisfied the remediation is safe, enable automatic remediation:
   ```hcl
   # terraform.tfvars
   automatic_remediation = true
   ```
   Then re-apply:
   ```bash
   terraform apply
   ```
   SSM will now run automatically each time Config detects a non-compliant bucket.

## Safety Defaults

This module deploys with `automatic_remediation = false` (dry-run mode).

**What this means on first deploy:** Config will start evaluating S3 buckets and marking non-compliant ones, but SSM will NOT automatically run any remediation. You can see the non-compliance list with the `non_compliant_resources_cli_command` output, but nothing will be changed in your account.

**Why dry-run first?** Fleet remediation is high-blast-radius. Enabling logging on hundreds of buckets simultaneously could generate unexpected storage costs or interfere with buckets that have specific logging requirements. Always review the list before enabling auto-remediation.

**To enable automatic remediation:**
1. Deploy with the default `automatic_remediation = false`
2. Run `terraform output non_compliant_resources_cli_command` and review the list
3. Add any buckets you want to exempt to `excluded_resource_ids` in `terraform.tfvars`
4. Set `automatic_remediation = true` in `terraform.tfvars`
5. Re-apply: `terraform apply`

## Inputs Reference

| Name | Type | Default | What to put here |
|------|------|---------|-----------------|
| `name_prefix` | `string` | required | Short identifier for your project or team. Used as a prefix for all resource names. Example: `"security"`, `"platform"`. |
| `log_destination_bucket` | `string` | required | Name of the S3 bucket that receives access logs. Must already exist. Ask your platform team if you don't know which bucket to use. |
| `log_destination_prefix` | `string` | `""` | Optional key prefix for log objects. Example: `"s3-access-logs/"`. Leave empty to write at the bucket root. |
| `tags` | `map(string)` | `{}` | Additional AWS resource tags. The module always applies `Module`, `ManagedBy`, and `Purpose` tags. |
| `automatic_remediation` | `bool` | `false` | Whether Config automatically triggers SSM remediation. Keep `false` until you have reviewed the non-compliance list. |
| `maximum_automatic_attempts` | `number` | `3` | How many times SSM retries a failed remediation per resource. Valid range: 1–25. |
| `retry_attempt_seconds` | `number` | `300` | Seconds between retry attempts. Valid range: 1–2,678,000. |
| `config_rule_input_parameters` | `map(string)` | `{}` | Extra parameters to pass to the Config rule (rarely needed for this managed rule). |
| `excluded_resource_ids` | `list(string)` | `[]` | Bucket names that should never have logging enabled by this module. The `log_destination_bucket` is already excluded automatically — do not add it here. |

## Outputs Reference

| Output | What it's useful for |
|--------|---------------------|
| `config_rule_arn` | Referencing this rule from Security Hub dashboards or cross-module compositions |
| `config_rule_name` | CLI queries and manual Config evaluations |
| `ssm_document_name` | Manual SSM execution for testing the remediation |
| `remediation_configuration_id` | Audit, debugging, and AWS Console navigation |
| `iam_role_arn` | Verifying the remediation role permissions in IAM |
| `non_compliant_resources_cli_command` | Ready-to-run CLI command listing all currently non-compliant buckets |

## How to Test This Module

Follow these steps to verify the module works end-to-end in a non-production account:

1. **Create a non-compliant test bucket** (no logging configured):
   ```bash
   aws s3api create-bucket --bucket my-test-bucket-no-logging-$(date +%s)
   ```

2. **Force a Config evaluation** (Config evaluates periodically, but you can trigger it manually):
   ```bash
   aws configservice start-config-rules-evaluation \
     --config-rule-names $(terraform output -raw config_rule_name)
   ```

3. **Wait ~60 seconds**, then verify the rule marks the bucket as non-compliant:
   ```bash
   # Run the command from this output:
   terraform output non_compliant_resources_cli_command
   ```

4. **Manually trigger the SSM document** against the test bucket:
   ```bash
   aws ssm start-automation-execution \
     --document-name $(terraform output -raw ssm_document_name) \
     --parameters \
       "BucketName=my-test-bucket-no-logging-XXXX,\
        TargetBucket=YOUR_LOG_DESTINATION_BUCKET,\
        TargetPrefix=s3-access-logs/,\
        ExcludedResourceIds= ,\
        AutomationAssumeRole=$(terraform output -raw iam_role_arn)"
   ```

5. **Verify the fix was applied:**
   ```bash
   aws s3api get-bucket-logging --bucket my-test-bucket-no-logging-XXXX
   ```
   You should see `LoggingEnabled` with `TargetBucket` and `TargetPrefix` in the response.

6. **Clean up the test bucket:**
   ```bash
   aws s3api delete-bucket --bucket my-test-bucket-no-logging-XXXX
   ```

## Per-resource Exclusion (Tier 1)

This is a **Tier 1** module — exclusions are enforced inside the SSM Automation document before any remediation runs.

### Inherent exclusions (automatic, always applied)

The `log_destination_bucket` is always excluded from remediation. This prevents an infinite log delivery loop: if the destination bucket were to log to itself, each log delivery would trigger another log object, which would trigger another delivery, growing exponentially.

You do not need to configure this — the module enforces it automatically in the `CheckExclusion` step.

### Operational exclusions (operator-configured)

Add bucket names to `excluded_resource_ids` in your Terraform to exempt them:

```hcl
module "s3_access_logging" {
  source = "..."

  name_prefix            = "my-project"
  log_destination_bucket = "my-central-logging-bucket"

  excluded_resource_ids = [
    "my-special-bucket-that-must-not-be-logged",
    "another-exempt-bucket",
  ]
}
```

The SSM wrapper checks the `excluded_resource_ids` list after the inherent exclusion check. If the current bucket appears in either exclusion, the automation exits cleanly without making any changes.

## Troubleshooting

**"Config evaluation shows zero results after deploying"**
Config evaluations run periodically (typically every 24 hours for periodic rules). Force an evaluation:
```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names $(terraform output -raw config_rule_name)
```
If you still see zero results after a few minutes, verify Config is enabled and recording S3 buckets.

**"SSM Automation execution failed with AccessDenied"**
The IAM role may not have the required permissions. Verify the role policy:
```bash
aws iam get-role-policy \
  --role-name $(basename $(terraform output -raw iam_role_arn)) \
  --policy-name s3-access-logging-remediation
```
The policy must include `s3:GetBucketLogging`, `s3:PutBucketLogging`, and `s3:GetBucketAcl`.

**"SSM Automation succeeded but logging is not enabled on the bucket"**
Check whether the bucket landed in an exclusion (inherent or operational) by reviewing the SSM execution output:
```bash
aws ssm get-automation-execution --automation-execution-id EXECUTION_ID \
  --query 'AutomationExecution.StepExecutions[0].Outputs'
```
The `CheckExclusion.reason` field explains why the bucket was skipped.

**"NoSuchBucket error in SSM Automation"**
The `log_destination_bucket` does not exist. Create it first (this module does not create the destination bucket).

**"AccessControlListNotSupported error"**
This error occurs when using the AWS managed `AWS-ConfigureS3BucketLogging` document against a bucket with Bucket Owner Enforced. This module avoids that problem by calling `PutBucketLogging` directly. If you see this error, verify the module version is correct.

**"Execution role cannot be assumed"**
The IAM role's trust policy restricts assume-role to `ssm.amazonaws.com` with an `aws:SourceAccount` condition. Verify the Config remediation configuration is passing the correct role ARN as `AutomationAssumeRole`.

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
