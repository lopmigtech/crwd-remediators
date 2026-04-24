# iam-wildcard-action-policy — operator dashboard

A single-file Python CLI that automates Steps 3–6 of [`../runbook.md`](../runbook.md) and renders a standalone HTML dashboard for stakeholders. Works against the deployed module without requiring an S3 report bucket — it reads everything from AWS Config, SSM, and IAM policy tags.

## Prerequisites

Same as the runbook:

- AWS profile pointing at the target account, with the module's operator managed policy attached.
- Python 3.9+.
- `pip install -r requirements.txt` (installs `boto3`).

The script uses the standard boto3 credential chain. Set `AWS_PROFILE` or pass `--profile`; set `AWS_REGION` or pass `--region`.

## Quick start

End-to-end — runs Steps 3→4→5→6 and writes a dashboard:

```bash
python dashboard.py run \
  --config-rule automation-iam-wildcard-action-policy \
  --ssm-document automation-iam-wildcard-action-policy \
  --assume-role-arn arn:aws-us-gov:iam::014280747320:role/automation-iam-wildcard-ssm \
  --limit 5 \
  --output dashboard.html
```

Open `dashboard.html` in any browser. No server, no JavaScript dependencies.

For a no-SSM-start refresh (stakeholder-safe — reads tags only):

```bash
python dashboard.py collect --output dashboard.html
```

## Subcommands

| Command | Runbook step | What it does |
|---|---|---|
| `start --limit N` | Step 3 | Start SSM `full-analysis` on the first N NON_COMPLIANT policies. Prints `policy=… exec=…` lines. |
| `watch EXEC [EXEC …]` | Step 4 | Poll each execution until terminal (`Success`/`Failed`/`Cancelled`/`TimedOut`). Accepts `exec=ID` lines on stdin. |
| `collect` | Steps 5+6 | Scan every customer-managed IAM policy's tags and render the dashboard. No SSM starts. |
| `run` | Steps 3→6 | End-to-end. Starts N executions, waits, then scans and renders. |
| `render --fixture FILE.json` | n/a | Re-render HTML from a previously-dumped state JSON. Offline — useful for iterating on the report layout or CI smoke tests. |

Split-command example (mirrors the runbook's manual flow):

```bash
python dashboard.py start --limit 3 | tee runs.txt
python dashboard.py watch < runs.txt
python dashboard.py collect --output dashboard.html
```

## What the dashboard shows

Sections are ordered so a non-technical stakeholder can scan top-to-bottom:

1. **Summary cards** — non-compliant count, analyzed count, pending analysis, Simple / Moderate / Complex totals, exempt, flapping.
2. **This run** *(only on `run`)* — each SSM execution's status, duration, and failure reason inline (no CloudWatch round-trip).
3. **Service wildcard summary** — per service: policies affected, how many are Simple + have a `SuggestedFix` (ready to scope), how many need review.
4. **Policy details** — one row per analyzed policy: category, attachment, per-service suggested fix parsed from the `SuggestedFix` tag, last-accessed services, last-evaluated timestamp.
5. **Unused wildcards** — policies whose `WildcardServices` contain services never accessed (strong remove-candidate signal, from runbook Appendix).
6. **Exempt policies** — `CrwdRemediatorExempt=true` with reason and expiry.
7. **Flapping policies** — sorted by most-recent `FlapLastDetected`.

The `SuggestedFix` column is read from the 256-char truncated IAM tag. For full per-service detail, configure `report_s3_bucket` on the module and use the existing `deployments/iam-test/generate-dashboard.py` script instead — this tool is intentionally scoped to the tag-only deployment.

## Troubleshooting

- **`AccessDenied` on `start_automation_execution`** — your operator policy is missing the permission, or `--assume-role-arn` does not match the module's `iam_role_arn` output. See runbook §Troubleshooting.
- **Executions stuck `InProgress` past `--timeout-seconds`** — CloudTrail `LookupEvents` throttling. Retry with a smaller `--limit`, or raise `--timeout-seconds`.
- **Scan is slow on large fleets** — raise `--workers` (default 20). The bottleneck is `iam:list_policy_tags`, which parallelizes safely.
- **Dashboard shows no analyzed policies** — run `start`/`run` first; Step 3 is what writes the tags Step 5 reads.

## Offline smoke test

```bash
python dashboard.py render --fixture tests/fixture.json --output /tmp/smoke.html
```

Renders the canned fixture without touching AWS. Good for iterating on renderer code.
