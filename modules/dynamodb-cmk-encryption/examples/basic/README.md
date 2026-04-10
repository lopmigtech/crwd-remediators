# Basic Example -- DynamoDB CMK Encryption

This example deploys the `dynamodb-cmk-encryption` module with default settings, including automatic KMS key creation.

## Usage

1. Copy `terraform.tfvars.example` to `terraform.tfvars`
2. Edit the values (at minimum, set `name_prefix`)
3. Run:

```bash
terraform init
terraform plan
terraform apply
```

## What This Creates

- An AWS Config rule detecting DynamoDB tables without CMK encryption
- An SSM Automation document with two phases (assess and encrypt)
- An IAM role for SSM to assume
- A customer-managed KMS key with automatic rotation
- A Config remediation configuration wired to run Phase 1 (assess) automatically

## After Deployment

Check non-compliant tables:

```bash
terraform output -raw non_compliant_resources_cli_command | bash
```

When ready to encrypt a specific table:

```bash
terraform output -raw phase2_encrypt_command
# Replace <TABLE_NAME> with the actual table name and run
```
