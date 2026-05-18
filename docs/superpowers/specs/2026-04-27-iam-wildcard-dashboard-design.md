# `iam-wildcard-action-policy-dashboard` module — design

**Date**: 2026-04-27
**Status**: Approved (sections 1-3)
**Author**: Miguel Lopez (with Claude)

---

## Context

The `iam-wildcard-action-policy` module produces operator-grade IAM policy tags (`WildcardCategory`, `SuggestedFix`, `LastAccessedServices`, etc.) when its SSM `full-analysis` action runs. Today, those tags are visible only via:

- The AWS console (per-policy IAM tag view, no aggregation)
- `aws iam list-policy-tags` CLI calls (manual, per-policy)
- The operator-CLI dashboard at `modules/iam-wildcard-action-policy/dashboard/dashboard.py` — runs locally, requires `boto3` + AWS credentials, produces a static HTML file (PR #1, merged 2026-04-27)

Stakeholders without local AWS tooling cannot easily view the aggregated state. They need a hosted, auto-refreshing dashboard with a stable URL they can bookmark.

## Problem

Provide a hosted version of the dashboard:

- Auto-refreshes on a schedule (no manual operator step)
- Accessible from a stable URL (bookmarkable)
- Authenticated (no public exposure → no S3 public-access findings on our own remediator account)
- Deployable as a standard Terraform module following repo conventions
- Operates in commercial AWS and GovCloud (`aws-us-gov` partition)

## Goals

1. New sibling Terraform module `modules/iam-wildcard-action-policy-dashboard/` that consumers opt into alongside the remediator module.
2. Dashboard auto-refreshes every N minutes (default 15) without manual operator action.
3. Stakeholders access via a single bookmarkable URL.
4. Zero new Security Hub / CRWD findings introduced by the deployment itself.
5. Free-tier-friendly cost envelope (< $0.05/month at typical usage).
6. Conforms to repo conventions: dynamic partition data source, no wildcard IAM actions, plan-mode tests, CHANGELOG, README.

## Non-Goals (v1)

- **Interactive controls** (kickoff buttons, exemption editing, etc.) — read-only display only. Operators continue to use the CLI for SSM actions. CLI ergonomics will be a separate effort after this module ships.
- **CloudFront / WAF / custom domains** — Lambda Function URL is the access surface.
- **Cognito / SSO / federated login** — `AWS_IAM` auth on the Function URL is sufficient for the operator audience that already has IAM credentials.
- **VPC-isolated networking** — Lambdas run in the public-internet runtime, which is fine for read-only Config/IAM/S3 calls.
- **KMS-CMK encryption on the bucket** — SSE-S3 (AES256) is sufficient for v1; add KMS later if required by environment policy.
- **Multi-region replication / DR** — single-region deployment.
- **Slack / email notifications** — out of scope; can be added as a separate module later.

## Architecture

```
                           ┌──────────────────────┐
   EventBridge schedule ─▶  │  Refresh Lambda      │
   (rate(15 minutes))      │  (read-only IAM)     │
                           │                      │
                           │  collect → render →  │
                           │  PutObject HTML      │
                           └─────────┬────────────┘
                                     ▼
                           ┌──────────────────────┐
                           │   S3 bucket          │
                           │   • Block Public Acc │
                           │   • SSE + versioned  │
                           │   • TLS-only policy  │
                           │   • access logging   │
                           └─────────┬────────────┘
                                     ▲
                                     │ s3:GetObject (via presign)
                                     │
   browser w/ SigV4 ───────▶  ┌──────┴───────────────┐
   (AWS-CLI, awscurl,          │  Redirect Lambda     │
    or signed bookmarklet)     │  (Function URL,      │
                               │   AWS_IAM auth)      │
                               │                      │
                               │  generates presigned │
                               │  URL → 302 redirect  │
                               └──────────────────────┘
```

### Components

**Refresh Lambda** — invoked by EventBridge on `rate(N minutes)` schedule. Calls Config `GetComplianceDetailsByConfigRule`, IAM `ListPolicies` + `ListPolicyTags` (parallelized via thread pool, 20 workers), STS `GetCallerIdentity`. Builds the dashboard state and renders HTML. Uploads `dashboard.html` to the S3 bucket with `Content-Type: text/html; charset=utf-8` and SSE-S3.

**S3 bucket** — private, all four Block Public Access flags on, SSE-S3 default encryption, versioning enabled, bucket policy denying `aws:SecureTransport=false`, server-access logging enabled if `var.access_log_bucket` is set.

**Redirect Lambda** — fronted by an `aws_lambda_function_url` with `authorization_type = "AWS_IAM"`. On invocation, generates a short-TTL presigned `GetObject` URL for `dashboard.html` and returns HTTP 302 with the presigned URL in the `Location` header.

### Why two Lambdas

The system is read-only with respect to *customer state* (no IAM tag writes, no SSM kickoffs). The only writes are scoped `s3:PutObject` on this module's own bucket. Splitting into two Lambdas keeps each role's permissions minimal:

- **Refresh** has read-only Config / IAM / STS perms + `s3:PutObject` only on `${bucket}/dashboard.html`.
- **Redirect** has only `s3:GetObject` on the same key (used internally by the SDK to generate the presigned URL signature) — no `s3:PutObject`, no Config / IAM / SSM at all.

Neither role has any perms that mutate customer state. The redirect Lambda's role specifically has no `config:*`, `iam:*`, or `ssm:*` perms.

### Why Lambda generates the URL on demand (vs static presigned URL output)

Presigned URLs are bound to the IAM principal that signed them and have a hard 7-day max TTL. Returning one as a Terraform output would force a re-`terraform apply` to refresh. The redirect Lambda generates URLs on demand using its own role's credentials, so the URL the stakeholder ultimately receives is freshly signed on each click.

## Module Layout

```
modules/iam-wildcard-action-policy-dashboard/
├── CHANGELOG.md
├── README.md
├── data.tf                    # aws_partition.current, aws_caller_identity.current, aws_region.current
├── main.tf                    # all resources
├── variables.tf
├── outputs.tf
├── versions.tf                # terraform >= 1.6.0, AWS provider ~> 5.0
├── examples/
│   └── basic/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── README.md
├── lambda/
│   ├── refresh/
│   │   ├── dashboard.py       # copy of operator-CLI script
│   │   └── handler.py         # ~40-line handler
│   └── redirect/
│       └── handler.py         # ~15-line handler
└── tests/
    └── plan.tftest.hcl        # ≥9 plan-mode assertions
```

### Resources (≈14 total)

- `aws_s3_bucket` (1) + `aws_s3_bucket_public_access_block` + `aws_s3_bucket_server_side_encryption_configuration` + `aws_s3_bucket_versioning` + `aws_s3_bucket_policy` (TLS-only) + `aws_s3_bucket_logging` (conditional, count = `var.access_log_bucket != null ? 1 : 0`)
- `aws_lambda_function` × 2 (refresh, redirect)
- `aws_iam_role` × 2 + `aws_iam_role_policy` × 2 (one inline policy per role)
- `aws_lambda_function_url` (1, on the redirect Lambda)
- `aws_cloudwatch_event_rule` + `aws_cloudwatch_event_target` + `aws_lambda_permission` (1 each, for the schedule)
- `aws_cloudwatch_log_group` × 2 (with retention)

## Inputs

| Variable | Type | Required | Default | Notes |
|---|---|---|---|---|
| `name_prefix` | string | ✅ | — | Standard repo convention; used for all resource naming |
| `tags` | map(string) | | `{}` | Standard |
| `config_rule_name` | string | ✅ | — | Wired from `module.iam_wildcard_action_policy.config_rule_name` |
| `refresh_schedule_minutes` | number | | `15` | Validated 5–60 |
| `presigned_url_ttl_seconds` | number | | `3600` | Validated 60–43200 (1 min – 12 hr) |
| `log_retention_days` | number | | `30` | Must be one of AWS CloudWatch-supported values: 1, 3, 5, 7, 14, 30, 60, 90, 180, 365, 400, 545, 731, 1827, 3653 |
| `access_log_bucket` | string | | `null` | If set, S3 server-access logs target this bucket. If `null`, logging is disabled and consumer accepts the resulting `s3-access-logging` finding (documented in README) |
| `excluded_resource_ids` | list(string) | | `[]` | **Repo Rule 11 / Tier 2** — IDs filtered out of the dashboard display |

## Outputs

| Output | Type | Use |
|---|---|---|
| `dashboard_url` | string | Lambda Function URL — what stakeholders bookmark |
| `bucket_name` | string | S3 bucket containing the rendered HTML (debugging / direct CLI access) |
| `refresh_lambda_function_name` | string | For `aws lambda invoke` to force an early refresh |
| `redirect_lambda_function_name` | string | For ops debugging |

## Resource naming (deterministic)

- S3 bucket: `${name_prefix}-iam-wildcard-dashboard-${data.aws_caller_identity.current.account_id}` (account-suffixed for global uniqueness)
- Refresh Lambda: `${name_prefix}-iam-wildcard-dashboard-refresh`
- Redirect Lambda: `${name_prefix}-iam-wildcard-dashboard-redirect`
- IAM roles: `${name_prefix}-iam-wildcard-dashboard-refresh`, `${name_prefix}-iam-wildcard-dashboard-redirect`
- EventBridge rule: `${name_prefix}-iam-wildcard-dashboard-schedule`
- Log groups: `/aws/lambda/${name_prefix}-iam-wildcard-dashboard-{refresh,redirect}`

## Lambda runtime + packaging

- Runtime: **python3.12** (matches existing `iam-wildcard-action-policy/lambda/` convention)
- Dependencies: stdlib + `boto3` only — both ship with the Lambda Python runtime, no layer or vendoring needed
- Refresh Lambda: 512 MB memory, 5 min timeout (covers fleet scan with 20-thread `iam:ListPolicyTags` parallelism)
- Redirect Lambda: 128 MB memory, 10 sec timeout (single S3 API call)
- Packaging: `archive_file` data source per Lambda, sourcing from `${path.module}/lambda/{refresh,redirect}/`

### Why copy `dashboard.py` rather than reference

The new module's `lambda/refresh/dashboard.py` is a **copy** of the operator-CLI script at `modules/iam-wildcard-action-policy/dashboard/dashboard.py`. Reasons:

1. The operator CLI stays usable — no breakage to anyone running it locally today.
2. Cross-module relative-path dependencies in `archive_file` are fragile if the repo layout changes.
3. The new module is independently sourceable — consumers vendoring just `iam-wildcard-action-policy-dashboard/` get a working module.

The DRY violation is acceptable for v1. If the dashboard logic evolves and the two copies drift, we extract to a shared `lib/` module — a future-state concern.

### Refresh Lambda environment

| Env var | Source |
|---|---|
| `CONFIG_RULE_NAME` | `var.config_rule_name` |
| `DASHBOARD_BUCKET` | `aws_s3_bucket.dashboard.id` |
| `EXCLUDED_RESOURCE_IDS` | `join(",", var.excluded_resource_ids)` |

### Redirect Lambda environment

| Env var | Source |
|---|---|
| `DASHBOARD_BUCKET` | `aws_s3_bucket.dashboard.id` |
| `PRESIGNED_TTL_SECONDS` | `var.presigned_url_ttl_seconds` |

## IAM (no wildcard actions, dynamic partition)

### Refresh Lambda role

- Trust: `lambda.amazonaws.com`
- Inline policy:
  - `config:GetComplianceDetailsByConfigRule` on `arn:${partition}:config:${region}:${account}:config-rule/${var.config_rule_name}`
  - `iam:ListPolicies` on `*` (no resource-level support for this action — documented inline)
  - `iam:ListPolicyTags` on `arn:${partition}:iam::${account}:policy/*`
  - `sts:GetCallerIdentity` on `*` (no resource-level support)
  - `s3:PutObject` on `${bucket_arn}/dashboard.html`
  - CloudWatch Logs `CreateLogStream` + `PutLogEvents` on the refresh log group

### Redirect Lambda role

- Trust: `lambda.amazonaws.com`
- Inline policy:
  - `s3:GetObject` on `${bucket_arn}/dashboard.html` (used internally by `generate_presigned_url`)
  - CloudWatch Logs `CreateLogStream` + `PutLogEvents` on the redirect log group

### Negative invariants (asserted in plan-mode tests)

- Neither role has any `ssm:*` action
- Neither role has `iam:Tag*` or `iam:Untag*`
- Neither role has `iam:PassRole`
- Neither role has any wildcard action (`*` or `<service>:*`)

## Security findings posture

| Finding | Mitigation |
|---|---|
| S3.1 / S3.2 / S3.8 — bucket public access | All four BPA flags enabled |
| S3.4 — default encryption | SSE-S3 (AES256) configured |
| S3.5 / CIS 2.1.5 — TLS-only | Bucket policy denying `aws:SecureTransport=false` |
| S3.7 — versioning | Enabled |
| S3.9 — server-access logging | Enabled if `var.access_log_bucket` set; if `null`, README documents the trade-off |
| Lambda.1 — public Lambda Function URL | Function URL has `AWS_IAM` auth, not `NONE` |
| IAM.1 / IAM.21 — wildcard actions | Plan-mode test asserts no wildcards; resources scoped to specific ARNs |

## Cost

At typical usage (15-min refresh, ~10 stakeholder loads/day):

| Component | Monthly |
|---|---|
| S3 storage (~10 KB × few versions) | $0.0001 |
| S3 GET (~3,000 requests) | $0.0012 |
| S3 PUT (~3,000 requests, refresh) | $0.015 |
| Data transfer out (~30 MB) | $0.0027 |
| Lambda — refresh (96 invocations/day, ~10s each, 512 MB) | $0 (free tier) |
| Lambda — redirect (~300 invocations/day, sub-second, 128 MB) | $0 (free tier) |
| EventBridge schedule | $0 (free tier) |
| CloudWatch Logs (~100 MB/month, 30-day retention) | ~$0.05 |
| **Total** | **< $0.10 / month** |

## Testing

### Plan-mode tests (`tests/plan.tftest.hcl`, 10 assertions; Rule 9 requires ≥5)

1. Refresh Lambda created with `runtime = "python3.12"`
2. Redirect Lambda created with `runtime = "python3.12"`
3. S3 bucket has all four `aws_s3_bucket_public_access_block` flags = `true`
4. S3 bucket versioning is `Enabled`
5. S3 bucket SSE configured with `AES256`
6. S3 bucket policy contains a `Deny` statement on `aws:SecureTransport = false`
7. EventBridge rule has `schedule_expression = "rate(${var.refresh_schedule_minutes} minutes)"`
8. Lambda Function URL has `authorization_type = "AWS_IAM"`
9. Refresh role's inline policy contains zero `ssm:*`, `iam:Tag*`, `iam:Untag*`, `iam:PassRole`, or `"*"` action entries
10. Redirect role's inline policy is limited to `s3:GetObject` on the bucket + CloudWatch Logs

### Manual smoke test (after first apply)

1. Wait ~30s after apply for first scheduled refresh, OR `aws lambda invoke --function-name ${refresh_lambda_function_name}` to force one
2. Verify `s3 ls s3://${bucket_name}/dashboard.html` shows recent timestamp
3. Hit the `dashboard_url` with a SigV4-signed GET (e.g., `awscurl --service lambda ${dashboard_url}` with `--include` to see the 302)
4. Follow the `Location` header to confirm the rendered HTML loads in a browser

## Deployment integration with existing setup

Consumers add to their existing Terraform:

```hcl
module "iam_wildcard_action_policy" {
  source      = "git::.../modules/iam-wildcard-action-policy"
  name_prefix = "crwd"
  # ... existing args
}

module "iam_wildcard_dashboard" {
  source            = "git::.../modules/iam-wildcard-action-policy-dashboard"
  name_prefix       = "crwd"
  config_rule_name  = module.iam_wildcard_action_policy.config_rule_name
  access_log_bucket = "my-org-access-logs-bucket"  # optional
  tags = {
    Project = "crwd-remediators"
  }
}

output "dashboard_url" {
  value = module.iam_wildcard_dashboard.dashboard_url
}
```

Stakeholders bookmark the URL and access via SigV4-signed requests (browser plugin, AWS CLI, or `awscurl`).

## Future work (not v1)

- Interactive kickoff controls (Web Lambda + Cognito/auth, separate spec)
- Slack / email integration for refresh notifications
- KMS-CMK encryption on the bucket
- Multi-region deployment for DR
- Shared `lib/` module if `dashboard.py` drift becomes painful
- CloudFront in front for stable bookmarkable URL with WAF / IP allowlist
- VPC-isolated Lambdas if compliance requires it

## Open questions

None at design time. All resolved during brainstorming.
