# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] — 2026-04-15

### Added
- `remediation_action` variable — wires the SSM document's `Action` parameter through Terraform, letting operators configure Config to auto-invoke `scope-simple` or `suggest-moderate` instead of hardcoded `analyze`.
- `evaluation_frequency` variable — adds a `ScheduledNotification` source_detail to the Config rule so it periodically re-evaluates all in-scope IAM policies (covers existing resources and ongoing drift). Default `TwentyFour_Hours`; `Off` disables the schedule.
- Flap-detection tags (`FlapCount`, `FlapDetected`, `FlapFirstSeen`, `FlapLastDetected`) emitted by `scope-simple` when the same policy is scoped twice within `flap_window_days` (default 7). Detection-only — does not change remediation behavior.
- Tag-based exemption mechanism — `CheckExclusion` reads `CrwdRemediatorExempt=true` tag on policies and skips remediation when paired with a non-empty `CrwdRemediatorExemptReason`. Respects `CrwdRemediatorExemptExpiry` dates. Variables: `tag_based_exemption_enabled` (default `true`), `exemption_tag_key`, `require_exemption_reason` (default `true`).
- Auto-exempt on flap threshold — opt-in behavior where the SSM document self-applies `CrwdRemediatorExempt=true` on policies whose `FlapCount` reaches `auto_exempt_flap_threshold`. Auto-exemptions carry a `CrwdRemediatorExemptExpiry` date (default 30 days out) and a `CrwdAutoExempted=true` marker for audit distinction. Off by default (`auto_exempt_on_flap_enabled = false`).
- README section "When policies are externally managed" documenting the three operator patterns (fix at source / exclude / accept) for resolving flap loops with Terraform/CFN/GitOps-managed policies.

### Changed
- Config rule now has a third `source_detail` block (`ScheduledNotification`) by default. Opt out by setting `evaluation_frequency = "Off"`.
- `CheckExclusion` step in the SSM document now reads IAM policy tags (`iam:ListPolicyTags`) in addition to the existing `excluded_resource_ids` list check. Existing SSM role already had this permission; no IAM changes required.
- Quick-start deployment guide now leads with pre-apply tagging of break-glass policies to match the new default-on tag-based-exemption workflow.

## [1.0.0] — 2026-04-09

### Added
- Initial module release.
- Config rule: CUSTOM_LAMBDA (no AWS managed rule detects `<service>:*` wildcards)
- SSM document: custom three-mode automation (analyze, scope-simple, suggest-moderate)
- Exclusion tier: Tier 1 (in-document enforcement via CheckExclusion step)
- Phase 1 (analyze): categorizes policies as Simple/Moderate/Complex and applies IAM tags
- Phase 2 (scope-simple): auto-replaces single-wildcard policies using CloudTrail data
- Phase 3 (suggest-moderate): generates replacement suggestions for multi-wildcard policies
