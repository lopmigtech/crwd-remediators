# Contributing to crwd-remediators

## Adding a new remediator module

Use the `authoring-a-remediator` Claude Code skill:

```
"add a remediator for S3 access logging"
```

The skill walks through a 17-step procedure covering interface design, scaffolding, writing, testing, and documentation. It auto-chains into the `reviewing-a-remediator` skill for quality gate validation before tagging.

## Triaging a new finding

Use the `triaging-a-finding` Claude Code skill:

```
"triage finding 142 — S3 access logging"
```

The skill checks the findings index, classifies the finding by detectability (AWS Config) and remediability (SSM Automation), and either points at an existing module or proposes a new one.

## Conventions

All conventions are documented in `~/.claude/skills/authoring-a-remediator/references/repo-conventions.md`. Key highlights:

- Every module deploys 4 core resources (Config rule + IAM role + remediation config + optional SSM doc)
- Every module defaults to `automatic_remediation = false` (dry-run)
- Every module ships a `tests/plan.tftest.hcl` with >= 5 assertions
- Prefer AWS managed Config rules over custom Lambda rules
- Two-tier exclusion model (Tier 1 in-document, Tier 2 operator-level)
- Dynamic partition for GovCloud portability — no hardcoded `arn:aws:`
