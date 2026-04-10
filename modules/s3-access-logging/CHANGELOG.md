# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
