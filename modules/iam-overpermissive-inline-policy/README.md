# iam-overpermissive-inline-policy

Detects inline IAM policies with overly permissive wildcards (`Action: "*"` and `<service>:*`) attached directly to roles, users, and groups. Tags the offending principal with findings so operators can triage from compliance dashboards or AWS CLI queries.

**GovCloud compatibility:** both partitions

## Usage

```hcl
module "iam_overpermissive_inline_policy" {
  source = "git::https://gitlab.com/lopmig.tech/crwd-remediators.git//modules/iam-overpermissive-inline-policy?ref=iam-overpermissive-inline-policy/v1.0.0"

  name_prefix = "prod-security"

  # Recommended first deployment — analyze mode is non-mutating, so it's safe to enable
  # automatic remediation immediately. Run for 24h, then review findings tags.
  automatic_remediation = true
  remediation_action    = "analyze"
}
```

## What this module covers

This module is one of three covering the four-quadrant IAM overpermissive-policy matrix:

| Pattern | Customer-managed policy | Inline policy on principal |
|---|---|---|
| `Action: "*"` (full wildcard) | `iam-policy-no-fullwildcard` (separate module) | **This module** |
| `<service>:*` (service wildcard) | `iam-wildcard-action-policy` (existing) | **This module** |

Inline policies are recorded as fields inside the principal's configurationItem (`rolePolicyList` / `userPolicyList` / `groupPolicyList`), so they are invisible to a Config rule scoped to `AWS::IAM::Policy`. This module's Config rule is scoped to `AWS::IAM::Role`, `AWS::IAM::User`, and `AWS::IAM::Group` to evaluate those embedded inline-policy lists directly.

## Architecture

```
Custom Lambda ──evaluates──> AWS Config Rule ──triggers──> Remediation Config ──invokes──> SSM Automation Doc
  (handler.py +              (multi-type scope:           (wire)                           (analyze mode)
   evaluator.py +              Role / User / Group)                                            │
   patterns.py +                                                                               │
   resource_ids.py)                                                                            ▼
                                                                              IAM Role (ssm_automation)
                                                                              ├ Read principals + inline policies
                                                                              └ Tag principals with findings
```

## Operational mode

| Mode | What it does | Mutates principal? | Safe for auto? | Status |
|---|---|---|---|---|
| `analyze` | Finds the principal, walks inline policies, classifies wildcards, writes findings tags | No (only writes tags — no policy change) | Yes | **v1.0** |
| `backup-only` | S3-backup the inline policy, no further mutation | Yes (writes to S3) | Yes | Reserved for next release |
| `scope-and-backup` | S3-backup → CloudTrail-discover specific actions → `PutRolePolicy` with scoped action list. Refuses on `Action: "*"`. | Yes — destructive | Caution | Reserved for next release |
| `delete-and-backup` | S3-backup → `DeleteRolePolicy` (or User/Group equivalents) | Yes — destructive | Operator-triggered only | Reserved for next release |

In v1.0 only `analyze` is selectable; the variable validation rejects other values. Mutating modes ship in a later release with their own backup-before-mutation semantics and IAM permissions.

## Findings tags

When `analyze` mode runs against a non-compliant principal, the SSM document writes these tags **on the principal** (not on the inline policy — inline policies have no independent identity to tag):

| Tag key | Value | Meaning |
|---|---|---|
| `OverpermissivePolicies` | CSV string | Names of inline policies on this principal that contain wildcards |
| `WildcardPattern` | `full` / `service` / `none` | Highest-severity pattern across the principal's inline policies |
| `WildcardCount` | integer string | Count of offending inline policies |
| `LastEvaluated` | ISO-8601 timestamp | When `analyze` last ran on this principal |

## Prerequisites

1. **AWS Config must be enabled** in the target account and recording IAM resources (`AWS::IAM::Role`, `AWS::IAM::User`, `AWS::IAM::Group`):

```bash
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].recordingGroup.allSupported'
```

Expected output: `true`. If `false`, enable Config before deploying this module.

2. **Terraform** `>= 1.6.0`
3. **AWS provider** `~> 5.0`
4. **IAM permissions** to create Config rules, IAM roles, Lambda functions, SSM documents, and Config remediation configurations.

## Quick start

```bash
cd modules/iam-overpermissive-inline-policy/examples/basic
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

List non-compliant principals:

```bash
terraform output -raw non_compliant_resources_cli_command | bash
```

Inspect findings tags on a principal:

```bash
aws iam list-role-tags --role-name <role-name>     # for Role principals
aws iam list-user-tags --user-name <user-name>     # for User principals
aws iam list-group-tags --group-name <group-name>  # for Group principals
```

## Two-tier exemption

This module supports two complementary exemption mechanisms checked in this order: list first, then tags.

### List-based (Terraform-managed)

Add composite resource IDs to `excluded_resource_ids`:

```hcl
excluded_resource_ids = [
  "role/BreakGlassAdmin",                       # exempt all inline policies on this role
  "user/legacy-admin#FullAccessInline",         # exempt one specific inline policy
  "group/Developers",                           # exempt all inline policies on this group
]
```

The composite format is `<kind>/<name>[#<inline-policy-name>]`:
- `<kind>` = `role` / `user` / `group` (lowercase)
- `<name>` = the principal's name (not its AWS resource ID)
- `#<inline-policy-name>` = optional, when present scopes the exemption to one inline policy on that principal

### Tag-based (self-service)

Resource owners tag their own principal:

| Tag on the principal | Required when | Meaning |
|---|---|---|
| `CrwdRemediatorExempt = "true"` | always | Gate — must be set for any tag-based exemption |
| `CrwdRemediatorExemptReason = "<text>"` | `require_exemption_reason = true` (default) | Non-empty justification; without this, the exemption is ignored |

Example:

```bash
aws iam tag-role \
  --role-name BreakGlassAdmin \
  --tags Key=CrwdRemediatorExempt,Value=true \
         Key=CrwdRemediatorExemptReason,Value="Break-glass role for SRE incident response"
```

## Inputs reference

| Input | Type | Default | What to put here |
|---|---|---|---|
| `name_prefix` | string | (required) | Short project identifier (e.g., `prod-security`); becomes part of all resource names |
| `tags` | map(string) | `{}` | Standard resource tags |
| `automatic_remediation` | bool | `false` | When true, Config invokes the SSM doc automatically. Safe to enable for `analyze` mode immediately since it's non-mutating |
| `remediation_action` | string | `"analyze"` | v1.0 supports `analyze` only |
| `evaluation_frequency` | string | `"TwentyFour_Hours"` | How often Config re-evaluates. `Off` disables the schedule (change-triggered only) |
| `excluded_resource_ids` | list(string) | `[]` | Composite resource IDs to exempt — see Two-tier exemption above |
| `tag_based_exemption_enabled` | bool | `true` | Honor `CrwdRemediatorExempt` tag on the principal |
| `exemption_tag_key` | string | `"CrwdRemediatorExempt"` | Tag key checked for exemption |
| `require_exemption_reason` | bool | `true` | Require non-empty `CrwdRemediatorExemptReason` companion tag |
| `inline_backup_s3_bucket` | string | `""` | Reserved for future mutating modes (S3 backup destination). Not enforced in v1.0 |
| `enable_role_remediation` | bool | `true` | Reserved for future mutating modes |
| `enable_user_remediation` | bool | `true` | Reserved for future mutating modes |
| `enable_group_remediation` | bool | `false` | Opt-in. Reserved for future mutating modes |
| `cloudtrail_lookback_days` | number | `90` | Reserved for future `scope-and-backup` mode |
| `min_actions_threshold` | number | `3` | Reserved for future `scope-and-backup` mode |

## Outputs reference

| Output | What it's for |
|---|---|
| `config_rule_arn` | Reference in dashboards or cross-module composition |
| `config_rule_name` | CLI/API queries against this specific rule |
| `ssm_document_name` | Triggering SSM executions manually |
| `remediation_configuration_id` | Audit trail and debugging |
| `iam_role_arn` | Passing to manual SSM executions as `AutomationAssumeRole` |
| `non_compliant_resources_cli_command` | Ready-to-run CLI command showing current non-compliance |
| `lambda_function_arn` | Debugging the Lambda evaluator |
| `lambda_role_arn` | Auditing Lambda permissions |

## How to test this module

1. Create a test IAM role with an inline policy containing a wildcard:
   ```bash
   aws iam create-role --role-name TestOverpermissive --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
   aws iam put-role-policy --role-name TestOverpermissive --policy-name InlineFullWildcard --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
   ```
2. Force Config evaluation:
   ```bash
   aws configservice start-config-rules-evaluation --config-rule-names <rule-name>
   ```
3. Verify Config flags the role as NON_COMPLIANT:
   ```bash
   aws configservice get-compliance-details-by-config-rule \
     --config-rule-name <rule-name> --compliance-types NON_COMPLIANT
   ```
4. Run the SSM document with `Action=analyze` on the role's resource ID
5. Verify tags were applied: `aws iam list-role-tags --role-name TestOverpermissive` — expect `OverpermissivePolicies`, `WildcardPattern`, `WildcardCount`, `LastEvaluated`
6. Test exemption: tag the role with `CrwdRemediatorExempt=true` + reason, run analyze again — verify the SSM doc returns `status: exempted`
7. Test exemption without reason: remove the reason tag — verify the SSM doc ignores the exemption and proceeds (returns `status: tagged`)

## Why this module exists alongside `iam-wildcard-action-policy`

The existing `iam-wildcard-action-policy` module's Config rule is scoped to `AWS::IAM::Policy`, which represents customer-managed policies only. Its Lambda evaluator additionally excludes the bare `Action: "*"` pattern on the assumption that the AWS-managed Config rule `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` would cover full wildcards in customer-managed policies.

That leaves two coverage gaps:

1. **Inline policies** — `aws iam put-role-policy`, the AWS Console's "Add inline policy" flow, and `boto3`-driven workflows produce inline policies that are recorded as fields inside the principal's configurationItem, not as separate `AWS::IAM::Policy` resources. This module fills that gap.
2. **`Action: "*"` in customer-managed policies** — addressed by a separate sibling module `iam-policy-no-fullwildcard` that wraps the AWS-managed rule per Rule 10.

## Roadmap

- **v1.1** — `backup-only` mode (S3-backup the inline policy, no further mutation). Operator-driven, useful pre-flight before any future mutating run.
- **v1.2** — `scope-and-backup` mode for `<service>:*` findings: S3-backup → CloudTrail-driven action discovery → `PutRolePolicy` with scoped action list. Refuses on `Action: "*"` (downgrades to `analyze` + `NeedsManualReview` tag).
- **v1.3** — `delete-and-backup` mode: S3-backup → `DeleteRolePolicy`. The right tool for inline `Action: "*"` cases that aren't load-bearing.
- **v2.0** — Group-fanout safeguards: when `enable_group_remediation = true` and a group's inline policy is about to be mutated, surface affected user count in the SSM execution log so the operator confirms blast radius.

<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs auto-generated section will be inserted here -->
<!-- END_TF_DOCS -->
