# iam-wildcard-action-policy

Detects and analyzes IAM customer-managed policies that use `<service>:*` wildcard actions (e.g., `ssm:*`, `s3:*`, `ec2:*`). Categorizes policies by complexity, tags them for tracking, and optionally auto-scopes single-wildcard policies using CloudTrail data.

**Proactive hardening — no finding mapped yet**

**GovCloud compatibility:** both partitions

## Architecture

This module creates the following resources:

```
Custom Lambda ──evaluates──> AWS Config Rule ──triggers──> Remediation Config ──invokes──> SSM Automation Doc
  (handler.py)            (iam-wildcard-action)           (wire)                       (3-mode document)
                                                                                          │
                                                          IAM Role (ssm_automation) <─────┘
```

1. **Custom Lambda Config Rule** — A Lambda function scans each customer-managed IAM policy for actions ending in `:*`. Flags policies with `<service>:*` as NON_COMPLIANT.
2. **SSM Automation Document** — A three-mode document that categorizes, auto-scopes, or suggests fixes depending on the `Action` parameter.
3. **IAM Role (SSM Automation)** — Assumed by the SSM document. Has permissions to read/tag/modify IAM policies and query CloudTrail.
4. **Config Remediation Configuration** — Wires the Config rule to the SSM document. Defaults to `analyze` mode.

### Three operational modes

| Mode | What it does | Safe for auto? | When to use |
|------|-------------|----------------|-------------|
| `analyze` | Categorize + tag (Simple/Moderate/Complex) | Yes | Phase 1: initial assessment |
| `scope-simple` | Auto-replace single-wildcard using CloudTrail data | Caution | Phase 2: after reviewing analyze results |
| `suggest-moderate` | Generate suggestions, do NOT apply | Yes | Phase 3: for multi-wildcard policies |
| `full-analysis` | Analyze + suggest in one pass (categorize, tag, query CloudTrail, write S3 report) | Yes | When you want complete visibility in a single evaluation |

## Prerequisites

1. **AWS Config must be enabled** in the target account and recording IAM policy resources. Verify:

```bash
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
```

Expected output: `true`.

2. **Terraform version** `>= 1.6.0`
3. **AWS provider version** `~> 5.0`
4. **IAM permissions** to create Config rules, IAM roles, Lambda functions, SSM documents, and Config remediation configurations.

## Quick start (deployment guide)

0. **Tag any break-glass or core-system policies that should be exempt from remediation.** Before `terraform apply`, apply these tags to each IAM policy you want the module to skip:

   ```bash
   aws iam tag-policy \
     --policy-arn arn:aws:iam::123456789012:policy/BreakGlassAdminPolicy \
     --tags Key=CrwdRemediatorExempt,Value=true \
            Key=CrwdRemediatorExemptReason,Value="Break-glass role for SRE incident response"
   ```

   The reason tag is required by default (see `require_exemption_reason`). Exemption tags without a non-empty reason are ignored. This is intentional: every exemption should be auditable.

1. Copy the example directory:
   ```bash
   cp -r modules/iam-wildcard-action-policy/examples/basic /path/to/my-deployment
   cd /path/to/my-deployment
   ```

2. Copy the tfvars template:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your values (see Inputs reference below)

4. Initialize and deploy:
   ```bash
   terraform init
   terraform plan    # Review what will be created
   terraform apply
   ```

5. Check what Config flagged:
   ```bash
   terraform output non_compliant_resources_cli_command
   # Copy and run the output command
   ```

6. Review the list of non-compliant policies. When satisfied, either:
   - Keep `automatic_remediation = false` and trigger SSM manually per-policy, or
   - Set `automatic_remediation = true` in tfvars and re-apply for automatic Phase 1 tagging

## Safety defaults

This module deploys with `automatic_remediation = false` (dry-run). After deploy, Config identifies non-compliant policies but SSM does NOT run remediation automatically. The default SSM action mode is `analyze` (categorize + tag), which is non-destructive even when automatic.

**To manually trigger analysis on a specific policy:**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=analyze"
```

**To manually trigger auto-scoping on a Simple policy:**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=scope-simple"
```

**WARNING:** `scope-simple` creates a new policy version. Always verify the policy is categorized as Simple first.

## Inputs reference

| Input | Type | Default | What to put here |
|-------|------|---------|-----------------|
| `name_prefix` | string | (required) | A short project/team identifier (e.g., `prod-security`). Becomes part of all resource names. |
| `tags` | map(string) | `{}` | Your standard resource tags (e.g., `{ Environment = "prod", Team = "security" }`). |
| `automatic_remediation` | bool | `false` | Leave `false` until you've reviewed the non-compliance list. Only set `true` after confirming the analyze results look correct. |
| `remediation_action` | string | `"analyze"` | Which SSM mode Config invokes automatically. `analyze` = tag-only (safe default), `scope-simple` = auto-rewrite Simple policies, `suggest-moderate` = generate suggestions, `full-analysis` = analyze + suggest in one pass. |
| `evaluation_frequency` | string | `"TwentyFour_Hours"` | How often Config re-evaluates all in-scope policies. `Off` disables the schedule (change-only evaluation). Options: `Off`, `One_Hour`, `Three_Hours`, `Six_Hours`, `Twelve_Hours`, `TwentyFour_Hours`. |
| `excluded_resource_ids` | list(string) | `[]` | IAM policy ARNs that should never be remediated. Use for admin policies, break-glass roles, or other legitimate wildcard users. Centrally-managed via Terraform. |
| `tag_based_exemption_enabled` | bool | `true` | Read policy tags for exemption. Default on — the intended workflow is to pre-tag break-glass policies with `CrwdRemediatorExempt=true` before `terraform apply`. |
| `exemption_tag_key` | string | `"CrwdRemediatorExempt"` | Tag key to check for exemption. Change only if aligning with existing CRWD tooling. |
| `require_exemption_reason` | bool | `true` | Require a non-empty `CrwdRemediatorExemptReason` tag alongside the boolean. Prevents silent bypass via bare tag application. |
| `auto_exempt_on_flap_enabled` | bool | `false` | Opt-in. When true, the module self-applies exemption tags on policies that flap `auto_exempt_flap_threshold` times. Pauses enforcement for `auto_exempt_duration_days`, then resumes. |
| `auto_exempt_flap_threshold` | number | `3` | Flap count that triggers auto-exempt (only when `auto_exempt_on_flap_enabled = true`). |
| `auto_exempt_duration_days` | number | `30` | How long auto-applied exemptions last before expiring. Shorter = more human-review pressure. |
| `flap_window_days` | number | `7` | Days within which successive scopes on the same policy count as a flap. Used only for the `FlapDetected` tag. |
| `cloudtrail_lookback_days` | number | `90` | How many days of CloudTrail history to scan in scope-simple/suggest-moderate modes. More days = better coverage. |
| `min_actions_threshold` | number | `3` | Minimum distinct actions found in CloudTrail before auto-scoping proceeds. Below this, the policy is tagged NeedsManualReview. |
| `report_s3_bucket` | string | `""` | S3 bucket name for JSON analysis reports. Leave empty to use policy tags only. |

## Outputs reference

| Output | What it's for |
|--------|--------------|
| `config_rule_arn` | Reference in Security Hub dashboards or cross-module composition |
| `config_rule_name` | CLI/API queries against this specific rule |
| `ssm_document_name` | Triggering SSM executions manually |
| `remediation_configuration_id` | Audit trail and debugging |
| `iam_role_arn` | Passing to manual SSM executions as AutomationAssumeRole |
| `non_compliant_resources_cli_command` | Ready-to-run CLI command showing current non-compliance |
| `lambda_function_arn` | Debugging the Lambda evaluator |
| `lambda_role_arn` | Auditing Lambda permissions |

## How to test this module

1. Create test IAM policies with wildcard actions (e.g., a policy with `ssm:*`)
2. Force Config evaluation:
   ```bash
   aws configservice start-config-rules-evaluation --config-rule-names <rule-name>
   ```
3. Verify Config flags the wildcard policies as NON_COMPLIANT:
   ```bash
   aws configservice get-compliance-details-by-config-rule \
     --config-rule-name <rule-name> --compliance-types NON_COMPLIANT
   ```
4. Run the SSM document with `Action=analyze` on a non-compliant policy
5. Verify tags were applied: `aws iam list-policy-tags --policy-arn <arn>`
6. Run with `Action=scope-simple` on a Simple policy and verify the threshold check

## Per-resource exclusion (Tier 1)

This module honors `excluded_resource_ids` at the SSM document level. The `CheckExclusion` step runs before any analysis or modification. Add IAM policy ARNs to the exclusion list for:

- **Admin policies** that legitimately need broad permissions
- **Break-glass roles** used in emergency situations
- **Service-linked policies** that cannot be modified
- **Policies under active migration** that you don't want tagged yet

Example:
```hcl
excluded_resource_ids = [
  "arn:aws:iam::123456789012:policy/AdminPolicy",
  "arn:aws:iam::123456789012:policy/BreakGlassPolicy",
]
```

## When policies are externally managed

If an IAM policy is managed by Terraform, CloudFormation, or any other declarative source of truth, and its source definition contains a wildcard action, this module's auto-remediation will fight the source:

```
git push (policy.tf has ssm:*)
  → terraform apply writes wildcard version
    → Config detects NON_COMPLIANT → SSM scopes → wildcard replaced
      → next terraform apply detects drift, re-writes wildcard
        → Config detects → SSM scopes again → flap
```

This is called the **flap loop**. The module detects and tags it (see "Flap-detection tags" below) but does not stop it — the remediation keeps doing its job. You have three options:

| Pattern | When to use | How |
|---------|-------------|-----|
| **Fix at source** | The owning team can update the source-of-truth | Run `Action=suggest-moderate` or `Action=analyze` to discover the action list, then update the Terraform/CFN to use specific actions instead of the wildcard. Submit a PR at source. |
| **Exclude, then fix at source on a schedule** | The fix requires change-window coordination | Either (a) tag the policy `CrwdRemediatorExempt=true` with a `CrwdRemediatorExemptReason` like `"awaiting Q2 IAM cleanup; owner=team-x"`, or (b) add the ARN to the module's `excluded_resource_ids` list. Resume remediation by removing the tag/entry after the source fix lands. |
| **Accept the flap** | Policy is test-only, short-lived, or the flap is a forcing function to push the owning team to act | Do nothing. The `FlapDetected=true` tag plus daily CloudTrail noise surfaces the problem to whoever owns the policy. |

### Find flapping policies

```bash
aws iam list-policies --scope Local --query "Policies[].Arn" --output text | while read arn; do
  last=$(aws iam list-policy-tags --policy-arn "$arn" \
    --query "Tags[?Key=='FlapLastDetected'].Value" --output text 2>/dev/null)
  [ -n "$last" ] && echo "$last $arn"
done | sort -r
```

Note: queries on `FlapLastDetected` (sorted by recency) rather than bare `FlapDetected=true` to show currently-active flaps first. `FlapDetected` persists as audit history even after the flap window expires.

### Flap-detection tags

The SSM document writes these tags whenever `scope-simple` runs on the same policy twice within `flap_window_days` (default 7):

| Tag | Value | Meaning |
|-----|-------|---------|
| `FlapCount` | integer string | Number of successive scopes within the flap window |
| `FlapDetected` | `"true"` | Set on second scope within the window; persists as audit history |
| `FlapFirstSeen` | ISO-8601 timestamp | When the first flap in the current episode was observed |
| `FlapLastDetected` | ISO-8601 timestamp | When the most recent flap was observed |

These tags are informational only — they do not change remediation behavior.

### Exemption tag schema

| Tag | Value | Who writes it | Required? |
|-----|-------|--------------|-----------|
| `CrwdRemediatorExempt` | `"true"` | Human operator OR module (auto-exempt) | Yes — gate |
| `CrwdRemediatorExemptReason` | Non-empty string describing the justification | Human operator OR module (auto-exempt) | Yes when `require_exemption_reason = true` (default) |
| `CrwdRemediatorExemptExpiry` | ISO-8601 date (`YYYY-MM-DD`) | Module only (auto-exempt writes this; human-applied exemptions typically omit it) | No — when absent, human-applied exemptions never expire |
| `CrwdAutoExempted` | `"true"` | Module only | Marks auto-applied exemptions; used by CrowdStrike filters to distinguish from human-applied |

Human-applied exemptions have no expiry by default. Auto-applied exemptions expire after `auto_exempt_duration_days` (default 30) and the module resumes remediation.

## Rollback procedure

If `scope-simple` auto-scoped a policy incorrectly:

1. Find the previous version from the `PreviousVersion` tag:
   ```bash
   aws iam list-policy-tags --policy-arn <arn> --query "Tags[?Key=='PreviousVersion'].Value" --output text
   ```
2. Set the previous version as default:
   ```bash
   aws iam set-default-policy-version --policy-arn <arn> --version-id <previous-version>
   ```
3. Delete the auto-scoped version if desired.

## Troubleshooting

- **"Config evaluation shows zero results"** — Is Config enabled? Is it recording `AWS::IAM::Policy`? Check with `aws configservice describe-configuration-recorders`.
- **"AccessDenied on SSM execution"** — Verify the SSM automation role has the required permissions. Check `terraform output iam_role_arn` and review the role's policies.
- **"Lambda timeout"** — The Lambda evaluator has a 60-second timeout. If you have many policy versions, increase `timeout` via the module or contact the module maintainer.
- **"NeedsManualReview tag applied"** — Expected behavior when CloudTrail has insufficient data. The `min_actions_threshold` is working correctly. Review the policy manually or increase `cloudtrail_lookback_days`.
- **"Not a Simple policy"** — The `scope-simple` action only works on policies with exactly one wildcard service. Use `suggest-moderate` for multi-wildcard policies.

## Why custom rule

No AWS managed Config rule detects `<service>:*` wildcard actions. The managed rule `iam-policy-no-statements-with-full-access` (source identifier `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS`) only catches `Action: "*"` (full wildcard across all services). It does NOT flag `ssm:*`, `s3:*`, `ec2:*`, or other service-scoped wildcards. This module's custom Lambda evaluator scans each customer-managed policy's default version for any action matching the `<service>:*` pattern.

## Batch processing workflow

For large environments with many wildcard policies:

1. Deploy with `automatic_remediation = true` and default `Action=analyze`
2. Wait for Config to evaluate all policies and SSM to tag them
3. Query tagged policies by category:
   ```bash
   aws iam list-policies --query "Policies[].Arn" --output text | while read arn; do
     cat=$(aws iam list-policy-tags --policy-arn "$arn" --query "Tags[?Key=='WildcardCategory'].Value" --output text 2>/dev/null)
     [ -n "$cat" ] && echo "$cat $arn"
   done
   ```
4. Run `scope-simple` on Simple policies (manually or via a script)
5. Run `suggest-moderate` on Moderate policies and review suggestions
6. Handle Complex policies manually

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
