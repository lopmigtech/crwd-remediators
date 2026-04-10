# crwd-remediators — Claude Code context

This is the `crwd-remediators` Terraform module repo. It contains fleet-remediator modules that deploy AWS Config rules + SSM Automation documents to detect and remediate CRWD/SecHub findings at scale.

## Skills

This repo is supported by three Claude Code skills under `~/.claude/skills/`:

- **`authoring-a-remediator`** — 17-step procedure for adding a new module. Say "add a remediator for X" to trigger.
- **`reviewing-a-remediator`** — 18-gate quality checklist. Say "review <module-name>" to trigger. Say "review and fix <module-name>" for auto-fix mode.
- **`triaging-a-finding`** — Decision tree for evaluating a CRWD/SecHub finding. Say "triage finding X" to trigger.

## Conventions

All repo conventions (11 hard rules, standard variables/outputs, file templates, naming, versioning) are documented in:
`~/.claude/skills/authoring-a-remediator/references/repo-conventions.md`

## Key rules

- Every module deploys 4 core resources: Config rule + IAM role + remediation config + optional SSM doc
- Dynamic partition always (`data.aws_partition.current.partition`) — no hardcoded `arn:aws:`
- No wildcard IAM actions — scoped wildcard resources allowed only in remediation roles per Rule 2
- Dry-run default (`automatic_remediation = false`) — Rule 8
- Plan-mode tests required (`tests/plan.tftest.hcl` with >= 5 assertions) — Rule 9
- Prefer AWS managed Config rules — Rule 10
- Two-tier exclusion model (Tier 1 in-document, Tier 2 operator-level) — Rule 11
- Terraform >= 1.6.0, AWS provider ~> 5.0
