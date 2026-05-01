# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0] — Unreleased

### Added

- **Cross-module unified findings view.** Two new optional inputs (`inline_config_rule_name`, `fullwildcard_config_rule_name`) wire the dashboard up to the `iam-overpermissive-inline-policy` and `iam-policy-no-fullwildcard` sibling modules. When either is set, the dashboard renders a new "Unified findings" table at the top of the page with a `Severity` / `Source` / `Resource` / `Pattern` / `Last evaluated` / `Actions` schema, severity-sorted (CRIT first), with severity-based color coding (red for `Action:*`, amber for `<service>:*`).
- **Per-row copy-to-clipboard CLI buttons.** Each unified finding row gets a "copy exempt CLI" button (correctly templated `aws iam tag-policy/role/user/group` with the right ARN/name pre-filled and a `REPLACE WITH JUSTIFICATION` placeholder) and a "copy remediate CLI" button (source-aware: SSM `start-automation-execution` for `iam-wildcard-action-policy` findings, `aws iam list-entities-for-policy` starter for full-wildcard findings, SSM analyze for inline findings).
- **Unified rollup card grid.** Top-of-page rollup with Critical / High / Exempt / Flapping counts across all sources, scoped to the deployment account.
- **Principal-tag scanner.** New `scan_principal_inline_tags` function paginates `iam:ListRoles`/`ListUsers`/`ListGroups` and reads `iam:ListRoleTags`/`ListUserTags`/`ListGroupTags` to surface tags written by the inline module (`OverpermissivePolicies`, `WildcardPattern`, `WildcardCount`, `LastEvaluated`).
- **Backward compatibility.** When the two new inputs are empty (default), the dashboard preserves v1.0 single-source rendering: only the existing module's "summary / executions / service summary / policy details / unused / exempt / flapping" sections render. Existing deployments require no changes.
- **`excluded_principal_ids`** input — composite ID (`<kind>/<name>`) list filtering principals out of the dashboard, mirroring `excluded_resource_ids` for the inline source.
- IAM permission expansion on the refresh role: `iam:ListRoles`, `iam:ListUsers`, `iam:ListGroups`, `iam:ListRoleTags`, `iam:ListUserTags`, `iam:ListGroupTags`. All read-only — the existing plan-mode invariant forbidding `iam:Tag*`/`iam:Untag*`/`iam:PassRole`/`*` still holds.
- 4 new plan-mode assertions: 3 confirming the new env vars default to empty strings, plus a new `unified_mode_env_vars_propagate` run with 3 assertions confirming the env vars are populated when the inputs are set.
- Clipboard JS fallback path: `navigator.clipboard` when in a secure context, falls back to `document.execCommand('copy')` via a hidden `<textarea>`.

### Changed

- `scan_fleet_tags` filter now also matches policies tagged with `WildcardPattern` (the `iam-policy-no-fullwildcard` module's tag) — prior versions would have missed those entries.
- `build_state` signature accepts `inline_rule_name`, `fullwildcard_rule_name`, and `inline_findings` keyword arguments. All optional and default to empty values, preserving backward compatibility.

### Notes for upgraders

- This is a breaking version bump only because the v1.0 → v2.0 jump signals "new top-of-page section above existing layout" which may surprise stakeholders bookmarking specific URL fragments. The actual interface (Terraform inputs, outputs, dashboard URL) is fully backward-compatible.
- To enable the unified view, instantiate the two new sibling modules (`iam-overpermissive-inline-policy`, `iam-policy-no-fullwildcard`) in the same root configuration and wire their `config_rule_name` outputs into the dashboard's new inputs.

## [1.0.0] — 2026-04-28

### Added

- Initial release. Two-Lambda architecture (refresh + redirect) hosting an auto-refreshing read-only dashboard for the `iam-wildcard-action-policy` remediator.
- Refresh Lambda (Python 3.12, 512 MB, 5 min timeout) runs on EventBridge `rate(15 minutes)` schedule by default. Calls Config + IAM (read-only), renders HTML, uploads to S3.
- Redirect Lambda (Python 3.12, 128 MB, 10 sec timeout) fronted by a Lambda Function URL with `AWS_IAM` auth. Generates short-TTL presigned URLs and returns HTTP 302 on each invocation.
- Private S3 bucket with all four Block Public Access flags, SSE-S3 default encryption, versioning, TLS-only bucket policy, optional server-access logging.
- Plan-mode tests at `tests/plan.tftest.hcl` (14 assertions) including negative invariants on IAM action lists.
- Unit tests for both Lambda handlers using `unittest.mock`.
- Basic example at `examples/basic/`.
