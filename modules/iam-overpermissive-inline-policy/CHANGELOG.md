# Changelog

All notable changes to the `iam-overpermissive-inline-policy` module are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this module adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — Unreleased

### Added

- Initial release. Detects inline IAM policies with overly permissive wildcards (`Action: "*"` and `<service>:*`) on `AWS::IAM::Role`, `AWS::IAM::User`, and `AWS::IAM::Group` principals.
- Custom Lambda Config rule with multi-resource-type scope (single rule, single Lambda evaluator branching internally on `resourceType`).
- Pure-function deep modules in `lambda/`:
  - `evaluator.py` — walks the principal's inline-policy field, returns Config compliance result.
  - `patterns.py` — `classify_action` / `classify_statement` for wildcard pattern detection. Respects `Effect: Allow`, ignores `NotAction` inversions.
  - `resource_ids.py` — `parse` / `format_id` for the composite `<principal-type>/<name>[#<inline-policy-name>]` exemption identifier.
- SSM Automation document with `analyze` mode: finds the principal by AWS resource ID, checks two-tier exemption (composite ID list + tag-based with required reason), reads inline policies via IAM API, classifies each statement, and tags the principal with `OverpermissivePolicies`, `WildcardPattern`, `WildcardCount`, `LastEvaluated`.
- Two-tier exemption schema (Rule 11): `excluded_resource_ids` list with composite IDs, plus `CrwdRemediatorExempt=true` tag on the principal with required `CrwdRemediatorExemptReason` companion.
- Conservative defaults (Rule 8): `automatic_remediation = false`, `remediation_action = "analyze"`, `enable_group_remediation = false` (opt-in due to fan-out blast radius).
- Partition-dynamic IAM ARN construction (Rule 2) — module deploys unchanged in commercial and GovCloud partitions.
- `examples/basic/` reference deployment.
- 20 Python unit tests covering the three deep modules; `tests/plan.tftest.hcl` with 4 runs and 17+ assertions per Rule 9.

### Reserved (placeholders for forward compatibility)

- `inline_backup_s3_bucket` variable — used by future mutating modes to write the original inline-policy document to S3 before any overwrite or delete. Not enforced in v1.0 because no mutating modes are selectable.
- `enable_role_remediation`, `enable_user_remediation`, `enable_group_remediation` — gate future mutating modes per principal type.
- `cloudtrail_lookback_days`, `min_actions_threshold` — used by future `scope-and-backup` mode for CloudTrail-driven action discovery.

### Out of scope for this release

- Mutating modes (`backup-only`, `scope-and-backup`, `delete-and-backup`) — ship in a later release with their own backup-before-mutation semantics.
- Resource-level or condition-level scoping of recommended replacements — action-list only.
- Detection of policy patterns other than `Action: "*"` and `<service>:*` (verb-prefix `service:Verb*`, `Resource: "*"`, `NotAction`/`NotResource`, trust-policy `Principal: "*"`).
- Dashboard integration — separate module update tracked in [#1](https://gitlab.com/lopmig.tech/crwd-remediators/-/work_items/1).
