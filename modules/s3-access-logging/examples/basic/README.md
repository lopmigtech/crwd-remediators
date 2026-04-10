# S3 Access Logging — Basic Example

Deploys the `s3-access-logging` remediator module with default settings (dry-run mode). Non-compliant S3 buckets will be identified by AWS Config but not automatically remediated until `automatic_remediation` is set to `true`.

Access logs are delivered to `example-access-logs-bucket` with prefix `s3-logs/`.

## Usage

```bash
terraform init
terraform plan
terraform apply
```
