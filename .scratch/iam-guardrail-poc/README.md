# IAM policy guardrail — PoC

Sandbox proof-of-concept for blocking overly-permissive IAM policies *before*
the boto3 call leaves the deploy host. Emulates what an Ansible Tower playbook
would do when it reads a policy body from CMDB and calls `iam:CreatePolicy`.

No AWS-side infrastructure. No Lambda. No remediation. Pure client-side
prevention with a structured failure mode.

## Layout

```
.
├── validator.py              — pure-Python validator (no AWS calls)
├── boto3_guardrail.py        — boto3 before-parameter-build hook
├── demo_deploy.py            — Tower-emulated deploy script
├── tests/
│   ├── test_validator.py     — unit tests for the validator
│   └── test_boto3_guardrail.py — integration tests for the hook
└── README.md
```

## Quickstart

```bash
cd .scratch/iam-guardrail-poc
python3 -m venv .venv && source .venv/bin/activate
pip install boto3 pytest

# Offline tests: validator + hook (no AWS credentials needed)
pytest tests/ -v

# Online demo: emulates Tower deploys (needs AWS creds in this shell)
python demo_deploy.py good            # exit 0 — policy created in your account
python demo_deploy.py bad-full        # exit 1 — guardrail rejects, no AWS call
python demo_deploy.py bad-scoped      # exit 1 — Action: [ec2:*, lambda:*]
python demo_deploy.py bad-notaction   # exit 1 — NotAction with Allow
python demo_deploy.py bad-mixed       # exit 1 — partial-bad policy
python demo_deploy.py inline ROLE     # exit 1 — PutRolePolicy with bad doc
```

## What the structured error looks like

When the guardrail rejects, `demo_deploy.py` prints:

```text
[BLOCKED] Guardrail rejected the deploy:
  PolicyValidationError: 2 violation(s) during CreatePolicy
    [1] BLOCKED_ACTION_PATTERN at Statement[0]: Action 'ec2:*' is in the blocked-pattern list. ...
        offending_value='ec2:*'
    [2] BLOCKED_ACTION_PATTERN at Statement[0]: Action 'lambda:*' is in the blocked-pattern list. ...
        offending_value='lambda:*'

[STRUCTURED_ERROR_CODE]
{
  "error": "PolicyValidationError",
  "operation": "CreatePolicy",
  "violation_count": 2,
  "violations": [
    {
      "rule": "BLOCKED_ACTION_PATTERN",
      "statement_index": 0,
      "detail": "Action 'ec2:*' is in the blocked-pattern list. ...",
      "offending_value": "ec2:*"
    },
    ...
  ]
}
```

The structured form is JSON on stderr, intended to be parsed by an outer
script (Ansible task wrapping the script, log shipper, etc.) for routing and
aggregation.

## Exit codes from `demo_deploy.py`

| Code | Meaning |
|------|---------|
| 0    | Deploy succeeded (policy created in AWS) |
| 1    | Guardrail rejected the policy — no AWS call was made |
| 2    | AWS-side error (creds, perms, name conflict, network) |
| 3    | Usage error (unknown scenario) |

## Default deny-list

Hardcoded in `validator.py::DEFAULT_BLOCKED_PATTERNS`:

```
*  iam:*  kms:*  secretsmanager:*  s3:*  ec2:*
lambda:*  rds:*  dynamodb:*  organizations:*  sts:*
```

Plus `Effect: Allow` + `NotAction` is always rejected (catches the
"deny-all-except-this-narrow-list" admin pattern).

The deny-list can be overridden via the `blocked_patterns` parameter on
`validate_policy_document` — useful if the EE-deployed version of this
package wants to read from a config file instead.

## Cleaning up after `demo_deploy.py good`

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCT}:policy/PoC-Good-Policy"
```

## What this PoC does NOT cover

- **Server-side revert** — bad policies submitted via boto3 *without* this
  hook installed (e.g., direct CLI from a developer laptop) are not caught.
  The production layer needs an EventBridge + Lambda revert backstop.
- **awscli wrapper** — bash scripts using the `aws` binary directly bypass
  the hook entirely. The production layer needs a wrapper at
  `/usr/local/bin/aws` that intercepts argv-level `--policy-document`.
- **Path-based exemption** — there's no escape valve for the legitimately-
  admin policies. Add when the rule set graduates beyond the PoC.
- **Configuration externalization** — the deny-list is hardcoded; production
  may want SSM Parameter Store or a config file.

The deliberate scope is "prove the boto3 interception works and produces a
useful structured error." Each item above is a follow-on if the PoC validates.
