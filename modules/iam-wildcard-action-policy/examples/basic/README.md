# Basic Example — iam-wildcard-action-policy

This example deploys the `iam-wildcard-action-policy` module with default settings.

## Usage

1. Copy `terraform.tfvars.example` to `terraform.tfvars`
2. Edit `terraform.tfvars` with your values
3. Run:

```bash
terraform init
terraform plan
terraform apply
```

4. After deploy, check what Config flagged:

```bash
terraform output non_compliant_resources_cli_command
# Copy and run the output command
```

5. When satisfied with the results, set `automatic_remediation = true` in `terraform.tfvars` and re-apply.
