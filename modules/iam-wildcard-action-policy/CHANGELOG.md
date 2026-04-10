# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-04-09

### Added
- Initial module release.
- Config rule: CUSTOM_LAMBDA (no AWS managed rule detects `<service>:*` wildcards)
- SSM document: custom three-mode automation (analyze, scope-simple, suggest-moderate)
- Exclusion tier: Tier 1 (in-document enforcement via CheckExclusion step)
- Phase 1 (analyze): categorizes policies as Simple/Moderate/Complex and applies IAM tags
- Phase 2 (scope-simple): auto-replaces single-wildcard policies using CloudTrail data
- Phase 3 (suggest-moderate): generates replacement suggestions for multi-wildcard policies
