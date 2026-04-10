# crwd-remediators

A Terraform-based remediation framework that deploys AWS Config rules + SSM Automation documents to detect and fix CrowdStrike (CRWD) and AWS Security Hub findings **fleet-wide**. Instead of fixing one resource at a time, each module remediates every non-compliant resource in an AWS account — automatically, continuously, and with built-in safety controls.

## The problem

CrowdStrike and Security Hub scans flag hundreds of resources per finding type — 200 S3 buckets missing access logging, 50 KMS keys without rotation, 30 IAM roles with wildcard permissions. Fixing these one at a time takes hundreds of hours, and new non-compliant resources appear immediately after.

## The solution

Deploy a remediator module once. AWS Config continuously detects every non-compliant resource. SSM Automation fixes them — now and forever. New resources that appear next week? Config catches them automatically.

```
┌──────────────────────────────────────────────────────────────────────┐
│                    One module deployment                             │
│                                                                      │
│  [AWS Config Rule]                                                   │
│       │  evaluates EVERY resource of the target type                │
│       │  (e.g., every S3 bucket in the account)                     │
│       ▼                                                              │
│  Non-compliant resources identified                                  │
│       │                                                              │
│       ▼                                                              │
│  [Remediation Configuration]                                         │
│       │  automatic = false (dry-run) by default                     │
│       │  operator reviews, then flips to true                       │
│       ▼                                                              │
│  [SSM Automation Document]                                           │
│       │  executes the fix on each non-compliant resource            │
│       │  checks exclusion list first (inherent + operational)       │
│       ▼                                                              │
│  Resource is now COMPLIANT                                           │
│       │                                                              │
│       ▼                                                              │
│  CrowdStrike + Security Hub findings auto-close on next scan        │
│                                                                      │
│  New non-compliant resources? Config catches them → loop repeats    │
└──────────────────────────────────────────────────────────────────────┘
```

## Architecture

Every remediator module deploys **4 core AWS resources**:

| # | Resource | Purpose |
|---|---|---|
| 1 | `aws_config_config_rule` | **Detection** — evaluates every resource of the target type for compliance. Uses AWS managed rules (~200+ available) or custom Lambda evaluators. |
| 2 | `aws_iam_role` | **Permissions** — SSM Automation assumes this role to execute the fix. Trust restricted to `ssm.amazonaws.com` with `aws:SourceAccount` condition. Actions are specific (e.g., `s3:PutBucketLogging`), never wildcards. |
| 3 | `aws_config_remediation_configuration` | **The wire** — links the Config rule to the SSM document. Config automatically feeds non-compliant resource IDs to SSM at runtime. Controls dry-run mode, retry behavior, and concurrency. |
| 4 | `aws_ssm_document` | **The fix** — Tier 1 modules ship a custom wrapper with exclusion support and direct API calls (`aws:executeAwsApi`). Tier 2 modules reference an AWS managed SSM Automation document. |

## How automatic remediation works

### Phase 1: Deploy (dry-run)

```bash
# Copy the example, fill in your values
cd modules/s3-access-logging/examples/basic
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# Deploy
terraform init
terraform plan    # review what will be created
terraform apply   # creates Config rule + IAM role + SSM doc + remediation config
```

After deploy, the module is in **dry-run mode** (`automatic_remediation = false`). This means:
- Config evaluates every resource and marks non-compliant ones — **this happens immediately**
- The remediation configuration exists but does **NOT** auto-trigger SSM
- Nothing is changed. Nothing is fixed. You're just watching.

### Phase 2: Review the non-compliance list

```bash
# Get the pre-built CLI command to see what Config flagged
terraform output non_compliant_resources_cli_command

# Run it — shows every non-compliant resource in the account
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name demo-s3-access-logging \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' \
  --output table
```

Output:
```
+------------------------------------+
|  demo-test-bucket-1-934791682619   |
|  demo-test-bucket-2-934791682619   |
|  demo-test-bucket-3-934791682619   |
|  ...200 more buckets...            |
+------------------------------------+
```

Review this list. Ask:
- Are there resources that should NOT be remediated? → add them to `excluded_resource_ids` in your tfvars
- Is the destination/target correct? → verify in your tfvars
- Are you ready for SSM to start fixing these? → proceed to Phase 3

### Phase 3: Enable automatic remediation

```hcl
# In your terraform.tfvars, change:
automatic_remediation = true
```

```bash
terraform apply   # updates the remediation config to automatic = true
```

Now:
- Config detects a non-compliant resource → SSM runs the fix **automatically**
- The SSM document's `CheckExclusion` step runs first:
  - Is this resource in the inherent exclusion list? (e.g., the log destination bucket) → **skip**
  - Is this resource in `excluded_resource_ids`? → **skip**
  - Otherwise → **remediate**
- Fixed resources become COMPLIANT on Config's next evaluation
- CrowdStrike and Security Hub auto-close the corresponding findings

### Phase 4: Continuous compliance (hands-off)

Once `automatic_remediation = true`, the module is self-healing:
- Someone creates a new S3 bucket without logging → Config flags it within 24 hours (or on the next change-triggered evaluation) → SSM enables logging → finding auto-closes
- No operator intervention needed
- The cycle repeats indefinitely until you `terraform destroy` the module

### What the operator controls

| Setting | Default | What it does |
|---|---|---|
| `automatic_remediation` | `false` | When `false` (dry-run): Config detects but SSM does NOT fix. When `true`: SSM auto-fixes every non-compliant resource. |
| `maximum_automatic_attempts` | `3` | How many times SSM retries a failed remediation per resource before giving up. |
| `retry_attempt_seconds` | `300` | Seconds between retry attempts (5 minutes default). |
| `excluded_resource_ids` | `[]` | Resource IDs that SSM should never touch, even when non-compliant. For resources that legitimately need to stay non-compliant (e.g., a production IAM role that needs wildcard permissions). |

### Exclusion model (two types)

**Inherent exclusions** — resources the module auto-detects should never be remediated, based on its own inputs. Example: the S3 access logging module knows the `log_destination_bucket` must NOT have logging enabled on itself (it would create an infinite loop of log deliveries). The SSM wrapper's `CheckExclusion` step handles this automatically — the operator doesn't need to add it to `excluded_resource_ids`.

**Operational exclusions** — resources only the operator knows should be exempt. Pass them via `excluded_resource_ids`. Example: a production S3 bucket that intentionally has logging disabled for cost reasons. Tier 1 modules honor this in the SSM document. Tier 2 modules delegate to AWS Config's native `put-remediation-exceptions` API.

## Prerequisites

Before deploying any module:

- **AWS Config must be enabled** and recording all supported resource types:
  ```bash
  aws configservice describe-configuration-recorders \
    --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
  ```
  Expected output: `true`. If `false` or empty, enable Config before proceeding.

- **Terraform >= 1.6.0** (required for `terraform test`):
  ```bash
  terraform --version
  ```

- **AWS CLI configured** with credentials for the target account:
  ```bash
  aws sts get-caller-identity
  ```

- **AWS provider ~> 5.0** (pinned in every module's `versions.tf`)

## Module index

| Module | Type | Finding(s) | Config Rule | Tier | Status |
|---|---|---|---|---|---|
| [s3-access-logging](modules/s3-access-logging/) | Detect-and-fix | Proactive hardening | `S3_BUCKET_LOGGING_ENABLED` (managed) | Tier 1 | Verified |
| [dynamodb-cmk-encryption](modules/dynamodb-cmk-encryption/) | Detect-and-assess | Proactive hardening | `DYNAMODB_TABLE_ENCRYPTED_KMS` (managed) | Tier 1 | Verified |
| [iam-wildcard-action-policy](modules/iam-wildcard-action-policy/) | Detect-and-analyze | IAM wildcard service actions | Custom Lambda | Tier 1 | Verified |

See [docs/findings-index.md](docs/findings-index.md) for the complete finding-to-module mapping.

## Quick start

```bash
# 1. Clone the repo
git clone https://gitlab.com/lopmig.tech/crwd-remediators.git
cd crwd-remediators

# 2. Pick a module
cd modules/s3-access-logging/examples/basic

# 3. Copy the tfvars template and fill in your values
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# 4. Deploy (dry-run by default)
terraform init
terraform plan
terraform apply

# 5. See what Config flagged
terraform output non_compliant_resources_cli_command
# Copy-paste and run the output command

# 6. Review the list. When satisfied, enable auto-remediation:
#    Edit terraform.tfvars → set automatic_remediation = true
terraform apply
```

## GovCloud portability

Every module is portable between AWS commercial and AWS GovCloud partitions without code changes. All ARNs use `data.aws_partition.current.partition` — never hardcoded `arn:aws:` or `arn:aws-us-gov:`. Author in commercial, deploy to GovCloud.

## Framework conventions

This repo is supported by three Claude Code skills that enforce conventions during development:

- **`authoring-a-remediator`** — 17-step procedure for adding a new module with an 8-question interface checklist
- **`reviewing-a-remediator`** — 18 quality gates with auto-fix feedback loop (catches hardcoded partitions, wildcard IAM, missing tests, wrong SSM doc names)
- **`triaging-a-finding`** — decision tree for evaluating whether a CRWD/SecHub finding belongs in this repo

Key rules enforced by the framework:

| Rule | What it prevents |
|---|---|
| Dynamic partition always | Modules breaking in GovCloud |
| No wildcard IAM actions | Over-privileged remediation roles |
| Dry-run default | Accidental fleet-wide changes on first deploy |
| Plan-mode tests required | Typos in Config rule names, wrong SSM doc references, missing resources |
| Prefer AWS managed Config rules | Unnecessary custom Lambda code |
| Two-tier exclusion model | Infinite loops (inherent) + production resource breakage (operational) |
| terraform.tfvars.example required | Junior developers editing core Terraform code instead of a safe template |
| Comprehensive README required | Modules shipped without deployment guides or troubleshooting |

Full conventions: `~/.claude/skills/authoring-a-remediator/references/repo-conventions.md`

## Contributing

See [docs/contributing.md](docs/contributing.md).

To add a new remediator module:
```bash
cd ~/crwd-remediators
claude    # start Claude Code
# Then say: "add a remediator for <finding description>"
```

## License

See [LICENSE](LICENSE).
