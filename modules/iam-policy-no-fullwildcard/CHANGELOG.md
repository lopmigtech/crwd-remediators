# Changelog

All notable changes to the `iam-policy-no-fullwildcard` module are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this module adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — Unreleased

### Added

- Initial release. Wraps the AWS-managed Config rule `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` with the standard remediation-config wiring per repo Rule 10 (prefer AWS-managed rules).
- SSM Automation document with `tag-and-route` mode: resolves Config's RESOURCE_ID (policy UUID) to a policy ARN via `iam:ListPolicies`, checks two-tier exemption, and tags the policy with `WildcardPattern=full`, `Severity=CRIT`, and `LastEvaluated`.
- Two-tier exemption schema (Rule 11): `excluded_resource_ids` ARN list plus tag-based `CrwdRemediatorExempt=true` with required `CrwdRemediatorExemptReason`.
- Conservative defaults (Rule 8): `automatic_remediation = false`, `remediation_action = "tag-and-route"` (non-mutating).
- Partition-dynamic IAM ARN construction (Rule 2) — module deploys unchanged in commercial and GovCloud partitions.
- `examples/basic/` reference deployment.
- `tests/plan.tftest.hcl` with 2 runs and 11 assertions per Rule 9.

### Out of scope for this release

- Auto-rewriting `Action: "*"` customer-managed policies. CloudTrail-driven scoping of full wildcards produces low-confidence policies (the action universe spans every service the role touched), so the design intentionally limits remediation to tagging + dashboard routing. Operators handle the actual scoping at source after reviewing the tagged policies.
- Detection of inline policies — handled by the sibling `iam-overpermissive-inline-policy` module.
- Detection of `<service>:*` wildcards in customer-managed policies — handled by the existing `iam-wildcard-action-policy` module.
- Dashboard integration — separate module update tracked in [#1](https://gitlab.com/lopmig.tech/crwd-remediators/-/work_items/1).
