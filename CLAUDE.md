# crwd-remediators — Claude Code context

This is the `crwd-remediators` Terraform module repo. It contains fleet-remediator modules that deploy AWS Config rules + SSM Automation documents to detect and remediate CRWD/SecHub findings at scale.

## Agent skills

### Issue tracker

Issues and PRDs live as GitLab issues at `gitlab.com/lopmig.tech/crwd-remediators` (use the `glab` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical labels with default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout. `CONTEXT.md` and `docs/adr/` at the repo root, both created lazily by `/grill-with-docs`. See `docs/agents/domain.md`.

## Key rules

- Every module deploys 4 core resources: Config rule + IAM role + remediation config + optional SSM doc
- Dynamic partition always (`data.aws_partition.current.partition`) — no hardcoded `arn:aws:`
- No wildcard IAM actions — scoped wildcard resources allowed only in remediation roles per Rule 2
- Dry-run default (`automatic_remediation = false`) — Rule 8
- Plan-mode tests required (`tests/plan.tftest.hcl` with >= 5 assertions) — Rule 9
- Prefer AWS managed Config rules — Rule 10
- Two-tier exclusion model (Tier 1 in-document, Tier 2 operator-level) — Rule 11
- Terraform >= 1.6.0, AWS provider ~> 5.0
