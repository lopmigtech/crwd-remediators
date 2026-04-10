# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] -- 2026-04-09

### Added
- Initial module release.
- Config rule: DYNAMODB_TABLE_ENCRYPTED_KMS (AWS managed)
- SSM document: custom two-phase wrapper (assess + encrypt)
- Exclusion tier: Tier 1 (in-document enforcement)
- Phase 1 (assess): tags non-compliant tables for human review, safe for automatic remediation
- Phase 2 (encrypt): applies customer-managed KMS key, manual trigger only
- Optional KMS key creation with automatic rotation
