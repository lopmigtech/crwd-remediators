# crwd-remediators

Library of Terraform modules that deploy AWS Config rules + SSM Automation documents to remediate CRWD/SecHub findings fleet-wide. Each module deploys detection + remediation as declarative infrastructure — Config identifies non-compliant resources at runtime and feeds them to SSM automatically.

## Architecture

Every module deploys **4 core resources**:

1. `aws_config_config_rule` — detects non-compliance (AWS managed or custom Lambda)
2. `aws_iam_role` — SSM Automation assumes this role to run the fix
3. `aws_config_remediation_configuration` — wires the Config rule to the SSM document
4. `aws_ssm_document` (optional) — custom wrapper for Tier 1 modules with exclusion support; Tier 2 modules reference an AWS managed document directly

All modules default to **dry-run** (`automatic_remediation = false`). Config identifies non-compliant resources but SSM does not auto-remediate until the operator explicitly flips the flag after reviewing the non-compliance list.

## Prerequisites

- **AWS Config must be enabled** in the target account and recording all supported resource types:
  ```bash
  aws configservice describe-configuration-recorders \
    --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
  ```
  Expected output: `true`

- **Terraform >= 1.6.0** (required for `terraform test`)
- **AWS provider ~> 5.0**

## Module index

| Module | Finding(s) | Config Rule | Status |
|---|---|---|---|
| *(none yet — use the `authoring-a-remediator` skill to add the first one)* | | | |

See [docs/findings-index.md](docs/findings-index.md) for the finding-to-module mapping.

## Usage

```hcl
module "s3_access_logging" {
  source = "git::https://gitlab.com/mlopez-group/crwd-remediators.git//modules/s3-access-logging?ref=s3-access-logging/v1.0.0"

  name_prefix            = "prod"
  log_destination_bucket = "my-central-logging-bucket"

  # Dry-run by default. Flip to true after reviewing the non-compliance list:
  # automatic_remediation = true
}
```

After deploy, check what Config flagged:
```bash
terraform output non_compliant_resources_cli_command
# Copy-paste the output command to see currently non-compliant resources
```

## Repo conventions

This repo follows the conventions documented in the Claude Code skill suite at `~/.claude/skills/authoring-a-remediator/references/repo-conventions.md`. Key rules:

- **11 hard rules** governing every module (dynamic partition, no wildcard IAM actions, dry-run default, plan-mode tests, etc.)
- **7 standard variables** every module accepts (`name_prefix`, `tags`, `automatic_remediation`, `maximum_automatic_attempts`, `retry_attempt_seconds`, `config_rule_input_parameters`, `excluded_resource_ids`)
- **6 standard outputs** every module exposes (`config_rule_arn`, `config_rule_name`, `ssm_document_name`, `remediation_configuration_id`, `iam_role_arn`, `non_compliant_resources_cli_command`)
- **Per-module semver** with tag format `<module-name>/v1.2.3`
- **Two-tier exclusion model**: Tier 1 (in-document enforcement via custom SSM wrapper) for high-risk fixes; Tier 2 (operator-level `put-remediation-exceptions`) for low-risk fixes

## Contributing

See [docs/contributing.md](docs/contributing.md).

## License

See [LICENSE](LICENSE).
