# iam-wildcard-action-policy

Detects and analyzes IAM customer-managed policies that use `<service>:*` wildcard actions (e.g., `ssm:*`, `s3:*`, `ec2:*`). Categorizes policies by complexity, tags them for tracking, generates CloudTrail-based replacement suggestions, and optionally auto-scopes single-wildcard policies.

**Proactive hardening — no finding mapped yet**

**GovCloud compatibility:** both partitions

## Usage

```hcl
module "iam_wildcard_action_policy" {
  source = "git::https://gitlab.com/lopmig.tech/crwd-remediators.git//modules/iam-wildcard-action-policy?ref=iam-wildcard-action-policy/v1.1.1"

  name_prefix = "prod-security"
  # Recommended first deployment — see Safety defaults section:
  # automatic_remediation = true
  # remediation_action    = "full-analysis"
  # report_s3_bucket      = "my-security-reports-bucket"
}
```

See the [Quick start](#quick-start-deployment-guide) section below for a full walkthrough, and the [Inputs reference](#inputs-reference) for all available variables.

## Architecture

This module creates the following resources:

```
Custom Lambda ──evaluates──> AWS Config Rule ──triggers──> Remediation Config ──invokes──> SSM Automation Doc
  (handler.py)            (iam-wildcard-action)           (wire)                       (4-mode document)
                                                                                          │
                                                          IAM Role (ssm_automation) <─────┘
```

1. **Custom Lambda Config Rule** — A Lambda function scans each customer-managed IAM policy for actions ending in `:*`. Flags policies with `<service>:*` as NON_COMPLIANT. The evaluator is service-agnostic — it catches wildcards for any AWS service without maintaining a service list.
2. **SSM Automation Document** — A four-mode document that categorizes, suggests fixes, auto-scopes, or performs a full analysis depending on the `Action` parameter.
3. **IAM Role (SSM Automation)** — Assumed by the SSM document. Has permissions to read/tag/modify IAM policies and query CloudTrail.
4. **Config Remediation Configuration** — Wires the Config rule to the SSM document. Defaults to `analyze` mode.

### Operational modes

| Mode | What it does | Modifies policy? | Safe for auto? | When to use |
|------|-------------|-----------------|----------------|-------------|
| `analyze` | Categorize + tag (`WildcardCategory`, `WildcardServices`, `AttachedTo`, `LastAccessedServices`) | No | Yes | Quick fleet-wide categorization when you don't need CloudTrail suggestions |
| `suggest-moderate` | Query CloudTrail per wildcard service, generate replacement suggestions, write S3 report | No | Yes | Targeted recommendations for specific policies |
| `full-analysis` | Analyze + suggest in one pass — categorize, tag, query CloudTrail, and write S3 report | No | Yes | **Recommended for most deployments.** Complete visibility in a single evaluation |
| `scope-simple` | Auto-replace single-wildcard policies using CloudTrail-discovered actions | **Yes — creates a new policy version** | Caution | After reviewing `full-analysis` results and confirming Simple policies are safe to auto-scope |

### Policy categories

The module categorizes each non-compliant policy based on the number of distinct `<service>:*` wildcard services it contains. The category determines which remediation tools are available and how much effort is required to fix it.

#### Simple (1 wildcard service)

A policy with exactly one service-scoped wildcard — for example, `"Action": ["ssm:*"]` or `"Action": ["s3:GetObject", "ec2:*", "logs:CreateLogGroup"]` (only `ec2:*` is a wildcard; the others are specific actions).

**Why these are easy to fix:** There's only one wildcard to replace, and the module can do it automatically. The `scope-simple` mode queries CloudTrail to discover which specific actions the attached role actually uses within that service (e.g., `ec2:DescribeInstances`, `ec2:RunInstances`), then creates a new policy version with those specific actions replacing the wildcard.

**How to remediate:**
- **Automatic:** Set `remediation_action = "scope-simple"` and the module replaces the wildcard fleet-wide. Policies that don't have enough CloudTrail data are tagged `NeedsManualReview` instead of modified (the `min_actions_threshold` safety gate).
- **Manual:** Run `Action=full-analysis` first to see the `SuggestedFix` tag or S3 report, review the recommended actions, then run `Action=scope-simple` on policies you're comfortable auto-scoping.
- **Rollback:** If a scoped policy breaks something, one command restores the previous version: `aws iam set-default-policy-version --policy-arn <arn> --version-id <PreviousVersion tag value>`.

**Real-world examples:** A Lambda execution role with `ssm:*` that only calls `ssm:GetParameter` and `ssm:GetParametersByPath`. A CI/CD pipeline role with `ecr:*` that only pushes images. These are quick wins — the fix is a 30-second auto-scope.

#### Moderate (2–3 wildcard services)

A policy with two or three service-scoped wildcards — for example, `"Action": ["s3:*", "ec2:*"]` or `"Action": ["lambda:*", "sns:*", "sqs:*"]`.

**Why these need more attention:** Each wildcard service requires its own CloudTrail analysis, and the results may differ in quality. One service might have strong CloudTrail data (20+ distinct actions discovered) while another shows nothing (the role was recently created, or the service has minimal API surface). The `scope-simple` mode **refuses to run** on Moderate policies because replacing multiple wildcards simultaneously increases risk — a mistake in one service's replacement could break the role.

**How to remediate:**
- **Review suggestions first:** Run `Action=full-analysis` with `report_s3_bucket` set. The S3 report contains per-service suggestions with `meets_threshold` flags telling you which services have enough CloudTrail evidence and which need manual review.
- **Fix at source:** Take the suggested replacement actions from the report, update the Terraform/CloudFormation/console definition at the source. This is safer than auto-scoping because a human reviews each service's replacement list.
- **Consider splitting:** If the policy serves multiple distinct purposes (e.g., `s3:*` for data access + `ec2:*` for infrastructure management), consider splitting it into two focused policies. This makes future scoping simpler and improves auditability.

**Real-world examples:** An application role with `s3:*` + `ec2:*` that reads S3 objects and describes EC2 instances. A monitoring role with `logs:*` + `cloudwatch:*` that creates log groups and reads metrics. These typically take 15–30 minutes to fix per policy with the S3 report guiding the work.

#### Complex (4+ wildcard services)

A policy with four or more service-scoped wildcards — for example, `"Action": ["ssm:*", "s3:*", "ec2:*", "iam:*", "lambda:*"]`.

**Why these need architectural review:** A policy with this many wildcards usually isn't a "we were lazy once" situation — it's a sign the policy grew organically over months or years as the role took on more responsibilities. Replacing wildcards one-by-one produces a policy with 50+ specific actions that's nearly impossible to audit. The better fix is usually restructuring: split the role's responsibilities into distinct roles with focused policies.

**How to remediate:**
- **Start with visibility:** Run `Action=full-analysis` to see the full picture. The S3 report shows per-service CloudTrail activity, `last_accessed_services` reveals which services the role is actively using (vs. wildcards that are granted but never exercised), and the `AttachedTo` tag shows which roles/users/groups are affected.
- **Identify unused wildcards:** Services that appear in `wildcard_services` but NOT in `last_accessed_services` or `suggested_replacements` may be safe to remove entirely. A policy with `iam:*` where CloudTrail shows zero IAM API calls likely doesn't need `iam:*` at all.
- **Plan the restructure:** Group the wildcard services by function (data access, compute, observability, security), design a focused policy per group, and migrate attached roles to the new policies. The module's per-service suggestions inform each new policy's action list.
- **Use exemptions during migration:** Tag the Complex policy with `CrwdRemediatorExempt=true` and a reason like `"Under active restructure — target completion Q3 2026"` to suppress repeated remediation attempts during the migration.

**Real-world examples:** A legacy "power user" policy that accumulated wildcards over two years. An early-stage startup's admin role that was never scoped. A shared-services role that handles logging, monitoring, deployment, and data access in a single policy. These are projects, not quick fixes — budget 2–4 hours per policy with a team review.

#### Prioritization

The `WildcardCategory` tag is applied by `analyze` and `full-analysis` modes. Use it to prioritize remediation:

1. **Simple policies first** — quick wins, automatable, low risk. Reduces your fleet-wide wildcard count fast.
2. **Moderate policies second** — targeted manual fixes guided by the S3 report's per-service suggestions.
3. **Complex policies last** — architectural work that requires planning, team coordination, and testing.

## Prerequisites

1. **AWS Config must be enabled** in the target account and recording IAM policy resources. Verify:

```bash
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
```

Expected output: `true`. If `false`, enable Config before deploying this module.

2. **S3 bucket for reports** (optional but recommended). The module writes JSON analysis reports to an existing bucket you provide via `report_s3_bucket`. The module does not create the bucket.
3. **Terraform version** `>= 1.6.0`
4. **AWS provider version** `~> 5.0`
5. **IAM permissions** to create Config rules, IAM roles, Lambda functions, SSM documents, and Config remediation configurations.

## Quick start (deployment guide)

### Step 0: Tag exempt policies

Before `terraform apply`, tag any break-glass, admin, or core-system policies that should never be remediated:

```bash
aws iam tag-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/BreakGlassAdminPolicy \
  --tags Key=CrwdRemediatorExempt,Value=true \
         Key=CrwdRemediatorExemptReason,Value="Break-glass role for SRE incident response"
```

The reason tag is required by default (`require_exemption_reason = true`). Exemption tags without a non-empty reason are ignored — this is intentional so every exemption is auditable.

### Step 1: Set up your deployment

```bash
cd modules/iam-wildcard-action-policy/examples/basic
cp terraform.tfvars.example terraform.tfvars
```

### Step 2: Edit terraform.tfvars

For a recommended first deployment with full visibility:

```hcl
name_prefix           = "prod"
automatic_remediation = true
remediation_action    = "full-analysis"
report_s3_bucket      = "my-existing-security-reports-bucket"

# Optional: lower threshold for services with minimal API usage
# min_actions_threshold = 1
```

### Step 3: Deploy

```bash
terraform init
terraform plan    # Review what will be created
terraform apply
```

### Step 4: Force an immediate evaluation (or wait 24 hours)

The module evaluates all IAM policies every 24 hours automatically. To trigger an immediate sweep:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names $(terraform output -raw config_rule_name)
```

### Step 5: View non-compliant policies

```bash
# Run the pre-built CLI command from terraform output
terraform output -raw non_compliant_resources_cli_command | bash

# Or with full details including annotations
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name $(terraform output -raw config_rule_name) \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[].{ResourceId:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId, Annotation:Annotation}' \
  --output table
```

### Step 6: Review S3 reports

After the SSM document runs on each non-compliant policy, JSON reports appear in your bucket:

```bash
aws s3 ls s3://my-existing-security-reports-bucket/iam-wildcard-reports/ --recursive
```

See the [S3 Reports](#s3-reports) section for the report format.

## Safety defaults

This module deploys with `automatic_remediation = false` (dry-run). After deploy, Config identifies non-compliant policies but SSM does NOT run remediation automatically. The default SSM action mode is `analyze` (categorize + tag), which is non-destructive even when automatic.

### Manual execution examples

**Analyze a specific policy (categorize + tag):**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=analyze"
```

**Full analysis on a specific policy (categorize + tag + CloudTrail suggestions + S3 report):**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=full-analysis,ReportS3Bucket=my-reports-bucket"
```

**Generate suggestions only (no categorization tags):**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=suggest-moderate"
```

**Auto-scope a Simple policy (creates a new policy version):**
```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw ssm_document_name)" \
  --parameters "ResourceId=<POLICY_ARN>,AutomationAssumeRole=$(terraform output -raw iam_role_arn),Action=scope-simple"
```

**WARNING:** `scope-simple` creates a new policy version. Always verify the policy is categorized as Simple first.

You can also run any mode from the **AWS Console**: go to **Systems Manager > Automation > Execute automation**, search for your document name, choose **Simple execution**, and fill in the parameters.

## S3 Reports

When `report_s3_bucket` is set, the `suggest-moderate` and `full-analysis` modes write a JSON report per policy to:

```
s3://<bucket>/iam-wildcard-reports/<policy-name>/<timestamp>.json
```

Each analysis creates a new timestamped file, giving you a history of analyses over time.

### Report format

```json
{
  "policy_arn": "arn:aws:iam::123456789012:policy/my-policy",
  "policy_name": "my-policy",
  "category": "Moderate",
  "wildcard_services": ["s3", "ec2"],
  "attached_to": "role/my-app-role",
  "suggestions": {
    "s3": {
      "current": "s3:*",
      "suggested_replacements": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "action_count": 3,
      "meets_threshold": true
    },
    "ec2": {
      "current": "ec2:*",
      "suggested_replacements": ["ec2:DescribeInstances"],
      "action_count": 1,
      "meets_threshold": false
    }
  },
  "assessed_date": "2026-04-16T07:00:00Z",
  "last_accessed_services": ["s3", "ec2"]
}
```

| Field | Description |
|-------|-------------|
| `category` | `Simple` (1 wildcard), `Moderate` (2-3), or `Complex` (4+) |
| `suggestions.<service>.suggested_replacements` | Specific actions discovered from CloudTrail that should replace the wildcard |
| `suggestions.<service>.meets_threshold` | `true` if enough actions were found to scope confidently; `false` means manual review recommended |
| `last_accessed_services` | Services the attached role(s) have actually used (from IAM ServiceLastAccessedDetails). Present only in `full-analysis` mode |

### Querying reports

**List all reports:**
```bash
aws s3 ls s3://<bucket>/iam-wildcard-reports/ --recursive
```

**Read a specific policy's latest report:**
```bash
aws s3 cp s3://<bucket>/iam-wildcard-reports/<policy-name>/<timestamp>.json - | python3 -m json.tool
```

**Aggregate across all reports (fleet summary):**
```bash
aws s3 ls s3://<bucket>/iam-wildcard-reports/ --recursive | awk '{print $4}' | while read key; do
  aws s3 cp "s3://<bucket>/$key" - 2>/dev/null
done | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        r = json.loads(line)
        for svc in r.get('wildcard_services', []):
            info = r['suggestions'][svc]
            print(f'{r[\"category\"]},{svc}:*,{r[\"policy_name\"]},{info[\"meets_threshold\"]},{info[\"action_count\"]}')
    except: pass
" | sort
```

## Inputs reference

| Input | Type | Default | What to put here |
|-------|------|---------|-----------------|
| `name_prefix` | string | (required) | A short project/team identifier (e.g., `prod-security`). Becomes part of all resource names. |
| `tags` | map(string) | `{}` | Your standard resource tags (e.g., `{ Environment = "prod", Team = "security" }`). |
| `automatic_remediation` | bool | `false` | Leave `false` until you've reviewed the non-compliance list. Set `true` after confirming results look correct. |
| `remediation_action` | string | `"analyze"` | Which SSM mode Config invokes automatically. Options: `analyze` (tag-only), `full-analysis` (analyze + suggest in one pass — **recommended**), `suggest-moderate` (suggestions only), `scope-simple` (auto-rewrite Simple policies). |
| `evaluation_frequency` | string | `"TwentyFour_Hours"` | How often Config re-evaluates all in-scope policies. `Off` disables scheduled evaluation (change-triggered only). Options: `Off`, `One_Hour`, `Three_Hours`, `Six_Hours`, `Twelve_Hours`, `TwentyFour_Hours`. |
| `report_s3_bucket` | string | `""` | Existing S3 bucket name for JSON analysis reports (used by `suggest-moderate` and `full-analysis`). Leave empty to use policy tags only. The module writes to the bucket — it does not create it. |
| `excluded_resource_ids` | list(string) | `[]` | IAM policy ARNs that should never be remediated. Centrally-managed via Terraform. Use for policies the platform team controls. |
| `tag_based_exemption_enabled` | bool | `true` | Read policy tags for exemption. Default on — intended workflow is to pre-tag break-glass policies with `CrwdRemediatorExempt=true` before `terraform apply`. |
| `exemption_tag_key` | string | `"CrwdRemediatorExempt"` | Tag key to check for exemption. Change only if aligning with existing CRWD tooling conventions. |
| `require_exemption_reason` | bool | `true` | Require a non-empty `CrwdRemediatorExemptReason` tag alongside the boolean. Prevents silent bypass via bare tag application. |
| `auto_exempt_on_flap_enabled` | bool | `false` | Opt-in. When true, the module self-applies exemption tags on policies that flap `auto_exempt_flap_threshold` times. Pauses enforcement for `auto_exempt_duration_days`, then resumes. |
| `auto_exempt_flap_threshold` | number | `3` | Flap count that triggers auto-exempt (only when `auto_exempt_on_flap_enabled = true`). |
| `auto_exempt_duration_days` | number | `30` | How long auto-applied exemptions last before expiring. Shorter = more human-review pressure. |
| `flap_window_days` | number | `7` | Days within which successive scopes on the same policy count as a flap. Used only for the `FlapDetected` tag. |
| `cloudtrail_lookback_days` | number | `90` | How many days of CloudTrail history to scan when generating suggestions (`suggest-moderate`, `full-analysis`, `scope-simple`). More days = better coverage but slower queries. |
| `min_actions_threshold` | number | `3` | Minimum distinct actions found in CloudTrail before auto-scoping proceeds. Below this threshold, the policy is tagged `NeedsManualReview` instead. Set to `1` if you have services that only perform a single API call. |

## Outputs reference

| Output | What it's for |
|--------|--------------|
| `config_rule_arn` | Reference in Security Hub dashboards or cross-module composition |
| `config_rule_name` | CLI/API queries against this specific rule |
| `ssm_document_name` | Triggering SSM executions manually |
| `remediation_configuration_id` | Audit trail and debugging |
| `iam_role_arn` | Passing to manual SSM executions as `AutomationAssumeRole` |
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
4. Run the SSM document with `Action=full-analysis` and `ReportS3Bucket=<bucket>` on a non-compliant policy
5. Verify tags were applied: `aws iam list-policy-tags --policy-arn <arn>` — expect `WildcardCategory`, `WildcardServices`, `AttachedTo`, `SuggestedFix`
6. Verify the S3 report was written: `aws s3 ls s3://<bucket>/iam-wildcard-reports/<policy-name>/`
7. Run with `Action=scope-simple` on a Simple policy — verify the `NeedsManualReview` threshold gate (if unattached) or the full auto-scope (if attached with CloudTrail data)
8. Test exemption: tag a policy with `CrwdRemediatorExempt=true` + reason, run any mode — verify `CheckExclusion` returns `skip`
9. Test exemption without reason: remove the reason tag — verify the SSM doc ignores the exemption and proceeds

## Per-resource exclusion (Tier 1)

This module supports two complementary exclusion mechanisms:

### List-based exclusion (Terraform-managed)

Add policy ARNs to `excluded_resource_ids` for centrally-managed exemptions:

```hcl
excluded_resource_ids = [
  "arn:aws:iam::123456789012:policy/AdminPolicy",
  "arn:aws:iam::123456789012:policy/BreakGlassPolicy",
]
```

### Tag-based exclusion (self-service)

Resource owners tag their own policies. The `CheckExclusion` step reads these tags before any analysis or modification:

- `CrwdRemediatorExempt = "true"` — the gate
- `CrwdRemediatorExemptReason = "<justification>"` — required when `require_exemption_reason = true` (default)

Both mechanisms are checked in order: list first, then tags. Either one is sufficient to skip.

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
| **Fix at source** | The owning team can update the source-of-truth | Run `Action=full-analysis` to discover the action list, then update the Terraform/CFN to use specific actions instead of the wildcard. The S3 report and `SuggestedFix` tag contain the recommended replacement. Submit a PR at source. |
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
- **"NeedsManualReview tag applied"** — Expected behavior when CloudTrail has insufficient data. The `min_actions_threshold` is working correctly. Review the policy manually or increase `cloudtrail_lookback_days`. Set `min_actions_threshold = 1` for services with minimal API usage.
- **"Not a Simple policy"** — The `scope-simple` action only works on policies with exactly one wildcard service. Use `full-analysis` or `suggest-moderate` to see recommendations for multi-wildcard policies.
- **"SuggestedFix shows no-data"** — The policy's attached role has no CloudTrail activity for that service. This can happen when: (a) the policy is unattached, (b) the role hasn't been used recently, or (c) there's a CloudTrail EventSource mismatch (e.g., `cloudwatch:*` actions log under `monitoring.amazonaws.com`). Check the S3 report for details.
- **"S3 report not written"** — Verify `report_s3_bucket` is set and the SSM role has `s3:PutObject` permission on the bucket. The module's IAM role includes permission for `s3:::*/iam-wildcard-reports/*` by default.

## Why custom rule

No AWS managed Config rule detects `<service>:*` wildcard actions. The managed rule `iam-policy-no-statements-with-full-access` (source identifier `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS`) only catches `Action: "*"` (full wildcard across all services). It does NOT flag `ssm:*`, `s3:*`, `ec2:*`, or other service-scoped wildcards.

This module's custom Lambda evaluator scans each customer-managed policy's default version for any action matching the `<service>:*` pattern. The evaluator is service-agnostic — it uses a single pattern match (`endswith(':*')`) and catches wildcards for any current or future AWS service without maintaining a service list.

## Recommended deployment workflow

For large environments with many wildcard policies:

1. **Tag exempt policies** — break-glass, admin, core-system (Step 0 above)
2. **Deploy with `full-analysis`** — `automatic_remediation = true`, `remediation_action = "full-analysis"`, `report_s3_bucket = "<bucket>"`
3. **Wait for the first evaluation sweep** (24 hours, or force immediately)
4. **Review S3 reports** — each policy gets a JSON report with category, wildcard services, and suggested replacements
5. **Query by category** to prioritize:
   ```bash
   aws iam list-policies --scope Local --query "Policies[].Arn" --output text | while read arn; do
     cat=$(aws iam list-policy-tags --policy-arn "$arn" --query "Tags[?Key=='WildcardCategory'].Value" --output text 2>/dev/null)
     [ -n "$cat" ] && echo "$cat $arn"
   done | sort
   ```
6. **Handle Simple policies** — review `SuggestedFix` tags or S3 reports, then either scope manually (`Action=scope-simple`) or switch to `remediation_action = "scope-simple"` for automatic fleet-wide scoping
7. **Handle Moderate/Complex policies** — use the S3 report's `suggested_replacements` per service, apply fixes at source (Terraform/CFN), and exempt any that legitimately need wildcards

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
