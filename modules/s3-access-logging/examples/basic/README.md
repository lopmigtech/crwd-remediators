# s3-access-logging — Basic Example

This example deploys the `s3-access-logging` remediator module with a minimal configuration. It creates an AWS Config rule that detects S3 buckets missing server access logging, an SSM Automation document that enables logging via a direct PutBucketLogging API call, and wires them together so Config can trigger remediation automatically.

## What this example deploys

- **AWS Config rule** (`S3_BUCKET_LOGGING_ENABLED`) — detects all S3 buckets in the account that do not have server access logging enabled
- **SSM Automation document** — a custom wrapper that checks exclusions (inherent + operator-defined) then calls `PutBucketLogging` directly
- **IAM role** — grants SSM Automation the minimum permissions needed (`s3:GetBucketLogging`, `s3:PutBucketLogging`, `s3:GetBucketAcl`)
- **Config remediation configuration** — links the Config rule to the SSM document so non-compliant buckets are fed into remediation automatically

## Usage

1. Copy `terraform.tfvars.example` to `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your values (at minimum: `name_prefix` and `log_destination_bucket`).

3. Initialize and validate:
   ```bash
   terraform init
   terraform plan
   ```

4. Apply:
   ```bash
   terraform apply
   ```

5. Review non-compliant buckets:
   ```bash
   terraform output non_compliant_resources_cli_command
   # Copy and run the output command
   ```

6. Once satisfied with the list, enable automatic remediation by setting `automatic_remediation = true` in `terraform.tfvars` and re-applying.

## Prerequisites

- AWS Config must be enabled and recording in the target account
- The `log_destination_bucket` must already exist and have a bucket policy allowing `logging.s3.amazonaws.com` to write objects
