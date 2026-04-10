# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-04-09

### Added
- Initial module release.
- Config rule: S3_BUCKET_LOGGING_ENABLED (AWS managed)
- SSM document: Custom Tier 1 wrapper around AWS-ConfigureS3BucketLogging
- Exclusion tier: Tier 1 (in-document enforcement)
- Inherent exclusion of the log destination bucket to prevent infinite logging loops
- Operational exclusion support via `excluded_resource_ids`
