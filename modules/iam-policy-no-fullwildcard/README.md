# iam-policy-no-fullwildcard

Detects customer-managed IAM policies that grant full wildcard access (`Action: "*"` paired with `Resource: "*"`) and tags them with critical severity for dashboard consumption. Wraps the AWS-managed Config rule `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` per repo Rule 10 (prefer AWS-managed rules where one exists).

**GovCloud compatibility:** both partitions

## Usage

```hcl
module "iam_policy_no_fullwildcard" {
  source = "git::https://gitlab.com/lopmig.tech/crwd-remediators.git//modules/iam-policy-no-fullwildcard?ref=iam-policy-no-fullwildcard/v1.0.0"

  name_prefix = "prod-security"

  # tag-and-route is non-mutating (writes severity tags only), so automatic
  # remediation is safe to enable on day one. Operators handle the actual
  # policy scoping at source after reviewing tagged policies.
  automatic_remediation = true
}
```

## What this module covers

This module is one of three covering the four-quadrant IAM overpermissive-policy matrix:

| Pattern | Customer-managed policy | Inline policy on principal |
|---|---|---|
| `Action: "*"` (full wildcard) | **This module** | `iam-overpermissive-inline-policy` |
| `<service>:*` (service wildcard) | `iam-wildcard-action-policy` (existing) | `iam-overpermissive-inline-policy` |

## Architecture

```
AWS-managed Config Rule ──triggers──> Remediation Config ──invokes──> SSM Automation Doc
  (IAM_POLICY_NO_STATEMENTS_              (wire)                       (tag-and-route mode)
   _WITH_FULL_ACCESS)                                                        │
                                                                             ▼
                                                            IAM Role (ssm_automation)
                                                            ├ Read policies + tags (for exemption)
                                                            └ Tag policies with severity
```

There is no Lambda evaluator — the AWS-managed rule does the detection. This module only adds the remediation wiring.

## Operational mode

| Mode | What it does | Mutates policy? | Safe for auto? | Status |
|---|---|---|---|---|
| `tag-and-route` | Resolves RESOURCE_ID to ARN, checks exemption, tags the policy with `WildcardPattern=full`, `Severity=CRIT`, `LastEvaluated` | No | Yes | **v1.0** |

**Why no auto-scope mode:** auto-scoping a `Action: "*"` policy from CloudTrail produces a policy spanning every service the policy's principals touched — typically 50+ low-confidence actions across 10+ services. The result is brittle and noisy. The design intentionally limits this module's remediation to tagging + dashboard routing; operators do the actual scoping at source after reviewing the flagged policies.

## Findings tags

When `tag-and-route` runs against a non-compliant customer-managed policy, the SSM document writes these tags **on the policy**:

| Tag key | Value | Meaning |
|---|---|---|
| `WildcardPattern` | `full` | Always `full` for this module — the AWS-managed rule only flags `Action:"*"+Resource:"*"` combinations |
| `Severity` | `CRIT` | Highest severity per the design grilling — full wildcards are admin-equivalent |
| `LastEvaluated` | ISO-8601 timestamp | When the SSM document last ran on this policy |

These tags feed into the unified dashboard module for cross-source visibility.

## Prerequisites

1. **AWS Config must be enabled** in the target account and recording IAM policy resources:

```bash
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
```

Expected output: `true`. If `false`, enable Config before deploying this module.

2. **Terraform** `>= 1.6.0`
3. **AWS provider** `~> 5.0`
4. **IAM permissions** to create Config rules, IAM roles, SSM documents, and Config remediation configurations.

## Quick start

```bash
cd modules/iam-policy-no-fullwildcard/examples/basic
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set name_prefix
terraform init
terraform plan
terraform apply
```

Force an immediate evaluation sweep (or wait 24 hours):

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names $(terraform output -raw config_rule_name)
```

List flagged policies:

```bash
terraform output -raw non_compliant_resources_cli_command | bash
```

Inspect findings tags on a specific policy:

```bash
aws iam list-policy-tags --policy-arn arn:aws:iam::<ACCOUNT>:policy/<NAME>
```

## Two-tier exemption

Same schema as the other modules in this family.

### List-based (Terraform-managed)

```hcl
excluded_resource_ids = [
  "arn:aws:iam::123456789012:policy/AdminPolicy",
  "arn:aws:iam::123456789012:policy/BreakGlassPolicy",
]
```

### Tag-based (self-service)

```bash
aws iam tag-policy \
  --policy-arn arn:aws:iam::<ACCOUNT>:policy/AdminPolicy \
  --tags Key=CrwdRemediatorExempt,Value=true \
         Key=CrwdRemediatorExemptReason,Value="Break-glass admin policy approved by SRE leadership"
```

The `CrwdRemediatorExempt=true` tag is the gate; `CrwdRemediatorExemptReason` is required when `require_exemption_reason = true` (default). Bare boolean exemptions without a non-empty reason are intentionally ignored.

## Inputs reference

| Input | Type | Default | What to put here |
|---|---|---|---|
| `name_prefix` | string | (required) | Short project identifier; becomes part of all resource names |
| `tags` | map(string) | `{}` | Standard resource tags |
| `automatic_remediation` | bool | `false` | When true, Config invokes the SSM doc automatically. Safe to enable for `tag-and-route` mode immediately since it's non-mutating |
| `remediation_action` | string | `"tag-and-route"` | v1.0 supports `tag-and-route` only |
| `evaluation_frequency` | string | `"TwentyFour_Hours"` | How often Config re-evaluates. `Off` disables the schedule |
| `excluded_resource_ids` | list(string) | `[]` | Customer-managed policy ARNs to exempt |
| `tag_based_exemption_enabled` | bool | `true` | Honor the `CrwdRemediatorExempt` tag on policies |
| `exemption_tag_key` | string | `"CrwdRemediatorExempt"` | Tag key checked for exemption |
| `require_exemption_reason` | bool | `true` | Require non-empty `CrwdRemediatorExemptReason` companion tag |
| `maximum_automatic_attempts` | number | `3` | Max retries for automatic remediation |
| `retry_attempt_seconds` | number | `300` | Seconds between retry attempts |

## Outputs reference

| Output | What it's for |
|---|---|
| `config_rule_arn` | Reference in dashboards |
| `config_rule_name` | CLI/API queries |
| `ssm_document_name` | Manual SSM execution |
| `remediation_configuration_id` | Audit trail |
| `iam_role_arn` | Manual SSM as `AutomationAssumeRole` |
| `non_compliant_resources_cli_command` | Ready-to-run CLI command for current non-compliance |

## How to test

1. Create a test customer-managed policy with full wildcard:
   ```bash
   aws iam create-policy \
     --policy-name TestFullWildcard \
     --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
   ```
2. Force Config evaluation:
   ```bash
   aws configservice start-config-rules-evaluation --config-rule-names <rule-name>
   ```
3. Verify the policy is flagged NON_COMPLIANT:
   ```bash
   aws configservice get-compliance-details-by-config-rule \
     --config-rule-name <rule-name> --compliance-types NON_COMPLIANT
   ```
4. After the SSM doc runs, verify tags: `aws iam list-policy-tags --policy-arn <arn>` — expect `WildcardPattern=full`, `Severity=CRIT`, `LastEvaluated=<timestamp>`
5. Test exemption: tag the policy with `CrwdRemediatorExempt=true` + reason, run again — verify SSM returns `status: exempted`
6. Test exemption without reason: remove the reason tag, run again — verify SSM ignores the exemption and proceeds (returns `status: tagged`)

## Why this module exists alongside `iam-wildcard-action-policy`

The existing `iam-wildcard-action-policy` module's custom Lambda evaluator deliberately excludes the bare `Action: "*"` pattern (see `lambda/handler.py`: `action != '*'`). The maintainer's design intent was that the AWS-managed `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` rule would cover that pattern, leaving the custom rule to fill the `<service>:*` gap that has no managed equivalent. This module deploys that AWS-managed rule with the standard remediation wrapper so both quadrants of customer-managed-policy detection ship as a coordinated pair.

## Roadmap

This module is intentionally minimal. The design grilling concluded that auto-rewriting full-wildcard customer-managed policies is too risky to justify ever shipping. Future enhancements that might land:

- **v1.1** — Optional CloudTrail-discovered action *suggestions* in the S3 report (not auto-applied), so operators have a starting point for manual scoping at source.
- **v2.0** — Cross-module coordination: when the inline module flags a principal that has *both* an inline `Action:"*"` and an attached customer-managed `Action:"*"` (this module's domain), surface the combined finding for prioritization.

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
