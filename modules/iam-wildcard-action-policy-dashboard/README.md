# `iam-wildcard-action-policy-dashboard`

Hosts an auto-refreshing read-only HTML dashboard for the
`iam-wildcard-action-policy` remediator. Renders the same data the operator
CLI script produces, but on a 15-minute schedule, served behind an IAM-authed
Lambda Function URL with no public exposure.

## Architecture

```
EventBridge ─▶ Refresh Lambda ─▶ S3 (private, encrypted, versioned)
                                       ▲
                  browser w/ SigV4 ─▶ Redirect Lambda (Function URL, AWS_IAM)
                                       │
                                       └─▶ 302 to presigned URL
```

- **Refresh Lambda** runs on a schedule (default 15 min). Read-only Config + IAM perms. Renders dashboard.html and uploads to S3.
- **Redirect Lambda** sits behind a Function URL with `AWS_IAM` auth. On each visit, generates a fresh short-TTL presigned URL and returns HTTP 302.
- **S3 bucket** is fully private: Block Public Access on, SSE-S3 encryption, versioning, TLS-only bucket policy, optional server-access logging.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `name_prefix` | string | ✅ | — | Prefix for all resource names |
| `tags` | map(string) | | `{}` | Tags applied to taggable resources |
| `config_rule_name` | string | ✅ | — | Wired from `module.iam_wildcard_action_policy.config_rule_name` |
| `refresh_schedule_minutes` | number | | `15` | 5–60 |
| `presigned_url_ttl_seconds` | number | | `3600` | 60–43200 |
| `log_retention_days` | number | | `30` | One of AWS-supported CloudWatch retention values |
| `access_log_bucket` | string | | `null` | If set, S3 server-access logs go here. If `null`, server-access logging is disabled and consumer accepts the resulting `s3-access-logging` finding |
| `excluded_resource_ids` | list(string) | | `[]` | Policy IDs filtered from the dashboard (Tier 2 exclusion) |
| `inline_config_rule_name` | string | | `""` | Optional. Config rule name from the `iam-overpermissive-inline-policy` module. When set, the dashboard scans IAM principals and includes inline findings in the unified findings table |
| `fullwildcard_config_rule_name` | string | | `""` | Optional. Config rule name from the `iam-policy-no-fullwildcard` module. When set, the dashboard includes `Action:*` customer-managed-policy findings (severity CRIT) in the unified findings table |
| `excluded_principal_ids` | list(string) | | `[]` | Composite IDs (`<kind>/<name>`) filtering inline findings from the dashboard |

## Outputs

| Name | Description |
|---|---|
| `dashboard_url` | Lambda Function URL — bookmark this |
| `bucket_name` | S3 bucket name |
| `refresh_lambda_function_name` | Refresh Lambda name (for `aws lambda invoke` to force refresh) |
| `redirect_lambda_function_name` | Redirect Lambda name |

## Usage

```hcl
module "iam_wildcard_action_policy" {
  source      = "git::.../modules/iam-wildcard-action-policy"
  name_prefix = "crwd"
  # ...
}

module "iam_wildcard_dashboard" {
  source            = "git::.../modules/iam-wildcard-action-policy-dashboard"
  name_prefix       = "crwd"
  config_rule_name  = module.iam_wildcard_action_policy.config_rule_name
  access_log_bucket = "my-org-access-logs-bucket" # recommended
}

output "dashboard_url" {
  value = module.iam_wildcard_dashboard.dashboard_url
}
```

## Accessing the dashboard

The Function URL uses `AWS_IAM` auth — clients must SigV4-sign the request.

### Option 1: AWS CLI

```bash
URL=$(terraform output -raw dashboard_url)
awscurl --service lambda "$URL" -i | head -1
# Follow the Location header
```

### Option 2: Browser with a SigV4 extension

Install a SigV4 signing extension (e.g., "AWS SigV4 Auth" for Chrome), configure
with your AWS credentials, then bookmark the URL.

### Option 3: AWS Console federated session

If you access via SAML federation, your console session can be re-used by the
extension to sign requests.

## Security posture

| Finding | Mitigation |
|---|---|
| S3.1 / S3.2 / S3.8 | All four BPA flags enabled |
| S3.4 | SSE-S3 default encryption |
| S3.5 / CIS 2.1.5 | Bucket policy denies `aws:SecureTransport=false` |
| S3.7 | Versioning enabled |
| S3.9 | Server-access logging if `access_log_bucket` set; otherwise documented trade-off |
| Lambda.1 | Function URL uses `AWS_IAM` auth, never `NONE` |
| IAM wildcards | Plan-mode test asserts no `ssm:*`, `iam:Tag*`, `iam:Untag*`, `iam:PassRole`, or `*` actions on either Lambda role |

## Cost

At default settings (15-min refresh, ~10 stakeholder loads/day): under $0.10/month. Lambda + EventBridge are well under free tier; S3 storage and requests are negligible; CloudWatch Logs is the largest line item at ~$0.05/month.

## Forcing an early refresh

```bash
aws lambda invoke --function-name "$(terraform output -raw refresh_lambda_function_name)" /dev/null
```

## Unified findings view (v2.0)

When the two optional inputs `inline_config_rule_name` and/or `fullwildcard_config_rule_name` are set, the dashboard renders an additional "Unified findings" section at the top of the page. This view aggregates findings from all configured Config rules into a single severity-sorted table:

| Column | What it shows |
|---|---|
| Severity | `CRIT` for `Action: "*"` findings, `HIGH` for `<service>:*` findings. Pattern-derived; not configurable. |
| Source | `CMP` for customer-managed-policy findings (either source rule), `Inline:Role` / `Inline:User` / `Inline:Group` for inline-policy findings on principals. |
| Resource | Policy ARN for CMP findings; composite `<kind>/<name>` plus ARN for principals. Inline findings also list the offending inline policy names from the `OverpermissivePolicies` tag. |
| Pattern | `Action:*` or `service:*`, color-coded to match the severity. |
| Last evaluated | ISO-8601 timestamp from the source's `LastEvaluated` tag. |
| Actions | Per-row copy-to-clipboard buttons. |

### Per-row copy buttons

Each finding row has a "copy exempt CLI" button that copies the correctly-templated `aws iam tag-{policy,role,user,group}` command with the right ARN or name pre-filled and a `REPLACE WITH JUSTIFICATION` placeholder for the reason tag.

A "copy remediate CLI" button is shown when the source has a well-defined operator action — SSM `start-automation-execution` for the existing wildcard module's findings, an `aws iam list-entities-for-policy` starter command for full-wildcard findings (which are not auto-remediated by design), and SSM analyze invocation for inline findings.

### Wiring example

```hcl
module "iam_wildcard_action_policy" {
  source      = "git::.../modules/iam-wildcard-action-policy"
  name_prefix = "crwd"
}

module "iam_overpermissive_inline_policy" {
  source      = "git::.../modules/iam-overpermissive-inline-policy"
  name_prefix = "crwd"
}

module "iam_policy_no_fullwildcard" {
  source      = "git::.../modules/iam-policy-no-fullwildcard"
  name_prefix = "crwd"
}

module "iam_wildcard_dashboard" {
  source                        = "git::.../modules/iam-wildcard-action-policy-dashboard"
  name_prefix                   = "crwd"
  config_rule_name              = module.iam_wildcard_action_policy.config_rule_name
  inline_config_rule_name       = module.iam_overpermissive_inline_policy.config_rule_name
  fullwildcard_config_rule_name = module.iam_policy_no_fullwildcard.config_rule_name
  access_log_bucket             = "my-org-access-logs-bucket"
}
```

When only `config_rule_name` is wired (the default), the dashboard renders v1.0 behavior identically — no unified section is emitted. Existing deployments need no changes.

## Module-CLI script parity

The Lambda's `dashboard.py` is a copy of the operator-CLI script at
`modules/iam-wildcard-action-policy/dashboard/dashboard.py`. The two are kept
in sync manually until divergence forces a shared library extraction.
