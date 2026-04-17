# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.1] — 2026-04-17

### Changed
- Removed the redundant `InherentExclusionBucket` SSM parameter. It always held the same value as `TargetBucket`, so the `CheckExclusion` step now derives the inherent exclusion (skip-if-logging-to-self) directly from `TargetBucket`. The Terraform remediation configuration no longer sets this parameter.

### Breaking (manual-invocation only)
- Operators invoking the SSM document directly (`aws ssm start-automation-execution`) must no longer pass `InherentExclusionBucket=...`; SSM will reject unknown parameters. The Config-triggered automatic path is unaffected. The README example has been updated.

## [1.0.0] — 2026-04-09

### Added
- Initial module release.
- Config rule: `S3_BUCKET_LOGGING_ENABLED` (AWS managed)
- SSM document: custom wrapper using `aws:executeAwsApi` with direct S3 `PutBucketLogging` API call
- Exclusion tier: Tier 1 (in-document enforcement)
- Detects S3 buckets missing server access logging and remediates by enabling logging to a configurable destination bucket
- Inherent exclusion: the `log_destination_bucket` is automatically excluded from remediation to prevent infinite log delivery loops
- Operational exclusion: operator-defined `excluded_resource_ids` list honored in the SSM wrapper's `CheckExclusion` step
- GovCloud compatible (both partitions) — uses `data.aws_partition.current.partition` throughout
