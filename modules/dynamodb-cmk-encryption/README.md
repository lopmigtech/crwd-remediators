# dynamodb-cmk-encryption

Detects DynamoDB tables not encrypted with a customer-managed KMS key and provides a two-phase remediation workflow: Phase 1 (automatic assessment and tagging) and Phase 2 (manual encryption with a CMK).

**Proactive hardening -- no finding mapped yet**

**GovCloud compatibility:** both partitions

## Usage

```hcl
module "dynamodb_cmk_encryption" {
  source = "git::https://gitlab.com/lopmig.tech/crwd-remediators.git//modules/dynamodb-cmk-encryption?ref=dynamodb-cmk-encryption/v1.0.0"

  name_prefix = "myteam"
  # create_kms_key defaults to true; set to false and pass kms_key_arn to bring your own key.
}
```

See the [Quick Start](#quick-start-deployment-guide) section below for a full walkthrough, and the [Inputs Reference](#inputs-reference) for all available variables.

## Architecture

This module deploys the standard crwd-remediator pattern plus an optional KMS key:

```
AWS Config Rule (DYNAMODB_TABLE_ENCRYPTED_KMS)
    |
    | detects non-compliant tables
    v
Config Remediation Configuration
    |
    | triggers (when automatic_remediation = true)
    v
SSM Automation Document (Action = "assess")
    |
    | Phase 1: tags table for review
    | Phase 2: encrypts table with CMK (manual trigger only)
    v
DynamoDB Table is tagged or encrypted
```

**Resources created:**

1. **AWS Config Rule** -- uses the AWS managed rule `DYNAMODB_TABLE_ENCRYPTED_KMS` to detect tables without CMK encryption.
2. **IAM Role** -- grants the SSM Automation document permissions to describe, tag, and update DynamoDB tables, and to use the KMS key.
3. **SSM Automation Document** -- custom Tier 1 wrapper with two modes: `assess` (safe for auto-remediation) and `encrypt` (manual only).
4. **Config Remediation Configuration** -- wires the Config rule to the SSM document with `Action=assess`.
5. **KMS Key** (optional) -- customer-managed key with automatic rotation, created when `create_kms_key = true`.

## Two-Phase Design

### Phase 1: Assess (automatic, safe)

When Config detects a non-compliant table and auto-remediation is enabled, the SSM document runs with `Action=assess`. This:

- Checks the exclusion list (skips excluded tables)
- Tags the table with the assessment tag (e.g., `CrwdRemediation=cmk-encryption-required`)
- Adds an `AssessedDate` tag with the timestamp
- Describes the table to record its current encryption status

**This is safe for `automatic_remediation = true`** -- it only reads and tags, never modifies encryption.

### Phase 2: Encrypt (manual, per-table)

After reviewing assessed tables, an operator manually triggers encryption on specific tables using the `phase2_encrypt_command` output. This:

- Checks the exclusion list
- Calls `UpdateTable` with `SSESpecification` to apply the CMK
- Tags the table with `CrwdRemediation=cmk-encryption-applied` and `EncryptedDate`

WARNING: Phase 2 affects all consumers of the table. Every Lambda, ECS task, EC2 instance, or other service that reads/writes the table MUST have `kms:Decrypt` and `kms:Encrypt` permissions on the CMK before you encrypt. Encrypting a table without granting these permissions will break all consumers immediately.

### How to check which roles access a table before encrypting

```bash
# Check CloudTrail for recent DynamoDB API calls on the table
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<TABLE_NAME> \
  --query 'Events[].{User:Username,Event:EventName,Time:EventTime}' \
  --output table

# List all IAM roles/users with DynamoDB permissions (broad check)
aws iam get-account-authorization-details \
  --filter LocalManagedPolicy AWSManagedPolicy \
  --query 'Policies[?contains(to_string(PolicyVersionList), `dynamodb`)].PolicyName' \
  --output table
```

## Prerequisites

1. **AWS Config must be enabled** and recording DynamoDB resources. Verify with:
   ```bash
   aws configservice describe-configuration-recorders \
     --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
   ```
   Expected output: `true`.

2. **IAM permissions** -- the deployer needs permissions to create Config rules, IAM roles, SSM documents, KMS keys, and Config remediation configurations.

3. **Terraform >= 1.6.0** installed.

4. **If providing your own KMS key** (`create_kms_key = false`): the key must exist and the SSM automation role must have `kms:DescribeKey` and `kms:CreateGrant` permissions on it.

## Quick Start (Deployment Guide)

1. Copy the example directory:
   ```bash
   cp -r modules/dynamodb-cmk-encryption/examples/basic /path/to/your/deployment
   ```

2. Copy the tfvars template:
   ```bash
   cd /path/to/your/deployment
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your values (see comments in the file for guidance).

4. Initialize Terraform:
   ```bash
   terraform init
   ```

5. Review the plan:
   ```bash
   terraform plan
   ```

6. Apply:
   ```bash
   terraform apply
   ```

7. Check what Config flagged:
   ```bash
   terraform output -raw non_compliant_resources_cli_command | bash
   ```

8. Review the list. When satisfied the assessment is correct, set `automatic_remediation = true` in terraform.tfvars and re-apply.

9. After assessment runs, review tagged tables and manually trigger Phase 2 on tables you want to encrypt:
   ```bash
   terraform output -raw phase2_encrypt_command
   # Replace <TABLE_NAME> with the actual table name
   ```

## Safety Defaults

This module deploys with `automatic_remediation = false` (dry-run). On first deploy:

- The Config rule is created and begins evaluating DynamoDB tables.
- Non-compliant tables (without CMK encryption) are flagged but NOT touched.
- Run `terraform output non_compliant_resources_cli_command` to see what was flagged.

When you flip `automatic_remediation = true`:

- The SSM document runs with `Action=assess` -- it ONLY tags tables, never encrypts.
- Encryption (Phase 2) is ALWAYS a manual step using the `phase2_encrypt_command` output.

## Inputs Reference

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | (required) | Prefix for all resource names. Use your project or team name (e.g., `myteam`). |
| `tags` | `map(string)` | `{}` | Additional tags merged with the standard crwd-remediator tags. |
| `automatic_remediation` | `bool` | `false` | Enable auto-assessment. Safe because Phase 1 only tags. Set to `true` after reviewing the non-compliance list. |
| `maximum_automatic_attempts` | `number` | `3` | How many times SSM retries assessment on a failed table. 1-25. |
| `retry_attempt_seconds` | `number` | `300` | Seconds between retry attempts. 1-2678000. |
| `config_rule_input_parameters` | `map(string)` | `{}` | Additional parameters for the Config rule. Usually not needed. |
| `excluded_resource_ids` | `list(string)` | `[]` | Table names to skip. Use for tables that legitimately use AWS-owned encryption for cost reasons. |
| `kms_key_arn` | `string` | `""` | ARN of an existing CMK. Only needed if `create_kms_key = false`. Find it with `aws kms list-aliases`. |
| `create_kms_key` | `bool` | `true` | Let the module create and manage a KMS key. Set to `false` if your org requires centrally managed keys. |
| `assessment_tag_key` | `string` | `"CrwdRemediation"` | Tag key used for assessment markers. Change if it conflicts with existing tags. |
| `sns_topic_arn` | `string` | `""` | SNS topic for notifications. Leave empty to skip. |

## Outputs Reference

| Name | Description |
|------|-------------|
| `config_rule_arn` | ARN of the Config rule, for dashboards and cross-module composition. |
| `config_rule_name` | Name of the Config rule, for CLI queries. |
| `ssm_document_name` | Name of the SSM doc, for manual execution. |
| `remediation_configuration_id` | ID of the remediation config, for audit. |
| `iam_role_arn` | ARN of the SSM role, for debugging permission issues. |
| `non_compliant_resources_cli_command` | Ready-to-run CLI command showing non-compliant tables. |
| `kms_key_arn` | ARN of the KMS key (created or provided). |
| `kms_key_id` | ID of the KMS key. |
| `phase2_encrypt_command` | Pre-built CLI command to trigger Phase 2 encryption on a specific table. |

## How to Test This Module

1. Create a DynamoDB table without CMK encryption:
   ```bash
   aws dynamodb create-table --table-name test-no-cmk \
     --attribute-definitions AttributeName=pk,AttributeType=S \
     --key-schema AttributeName=pk,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```

2. Force a Config evaluation:
   ```bash
   aws configservice start-config-rules-evaluation \
     --config-rule-names $(terraform output -raw config_rule_name)
   ```

3. Verify the table is flagged as NON_COMPLIANT (wait 60 seconds for evaluation):
   ```bash
   terraform output -raw non_compliant_resources_cli_command | bash
   ```

4. Manually trigger Phase 1 (assess):
   ```bash
   aws ssm start-automation-execution \
     --document-name $(terraform output -raw ssm_document_name) \
     --parameters "TableName=test-no-cmk,Action=assess,AutomationAssumeRole=$(terraform output -raw iam_role_arn),KmsKeyArn=$(terraform output -raw kms_key_arn),AssessmentTagKey=CrwdRemediation"
   ```

5. Verify the table was tagged:
   ```bash
   aws dynamodb list-tags-of-resource \
     --resource-arn arn:aws:dynamodb:$(aws configure get region):$(aws sts get-caller-identity --query Account --output text):table/test-no-cmk
   ```

6. Optionally trigger Phase 2 (encrypt) and verify SSE status:
   ```bash
   # Use the phase2_encrypt_command output, replacing <TABLE_NAME> with test-no-cmk
   aws dynamodb describe-table --table-name test-no-cmk --query 'Table.SSEDescription'
   ```

## Per-Resource Exclusion (Tier 1)

This module honors `excluded_resource_ids` at the SSM document level. The first step of the automation checks whether the current table name is in the exclusion list and exits cleanly if so.

**When to exclude tables:**

- Tables that legitimately use AWS-owned encryption for cost savings (no CMK charges).
- Tables in development environments where CMK encryption adds unnecessary cost.
- Third-party managed tables where you cannot control the encryption configuration.

```hcl
module "dynamodb_cmk" {
  source = "../../modules/dynamodb-cmk-encryption"

  name_prefix           = "myteam"
  excluded_resource_ids = ["legacy-table-1", "dev-scratch-table"]
}
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Config evaluation shows zero results | Is Config enabled? Run `aws configservice describe-configuration-recorders` |
| AccessDenied on SSM execution | Check the IAM role permissions. Run `aws iam get-role-policy --role-name <role-name> --policy-name <policy-name>` |
| "Table not found" during Phase 2 | Verify the table name matches exactly (case-sensitive). Run `aws dynamodb list-tables` |
| KMS key access denied during Phase 2 | Ensure the KMS key policy grants `kms:CreateGrant` to the SSM role. Check `aws kms get-key-policy --key-id <key-id> --policy-name default` |
| Phase 2 breaks table consumers | Every service accessing the table needs `kms:Decrypt` and `kms:Encrypt` on the CMK. Add these permissions BEFORE encrypting. |

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
