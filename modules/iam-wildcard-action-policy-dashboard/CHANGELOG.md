# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-04-28

### Added

- Initial release. Two-Lambda architecture (refresh + redirect) hosting an auto-refreshing read-only dashboard for the `iam-wildcard-action-policy` remediator.
- Refresh Lambda (Python 3.12, 512 MB, 5 min timeout) runs on EventBridge `rate(15 minutes)` schedule by default. Calls Config + IAM (read-only), renders HTML, uploads to S3.
- Redirect Lambda (Python 3.12, 128 MB, 10 sec timeout) fronted by a Lambda Function URL with `AWS_IAM` auth. Generates short-TTL presigned URLs and returns HTTP 302 on each invocation.
- Private S3 bucket with all four Block Public Access flags, SSE-S3 default encryption, versioning, TLS-only bucket policy, optional server-access logging.
- Plan-mode tests at `tests/plan.tftest.hcl` (14 assertions) including negative invariants on IAM action lists.
- Unit tests for both Lambda handlers using `unittest.mock`.
- Basic example at `examples/basic/`.
