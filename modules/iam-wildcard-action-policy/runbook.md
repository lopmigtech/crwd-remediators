# IAM Wildcard Action Policy Remediator — Operator Runbook

A step-by-step guide for operating the deployed `iam-wildcard-action-policy` fleet-remediator in the GovCloud account. Walk through these steps in order on first use; after that, jump to any step as needed.

---

## Deployment reference

| Item | Value |
|---|---|
| Partition | `aws-us-gov` |
| Region | `us-gov-west-1` |
| Account | `014280747320` |
| Config rule name | `automation-iam-wildcard-action-policy` |
| SSM document name | `automation-iam-wildcard-action-policy` |
| SSM automation role ARN | `arn:aws-us-gov:iam::014280747320:role/automation-iam-wildcard-ssm` |
| Lambda evaluator | `automation-iam-wildcard-evaluator` |
| Current remediation action | `full-analysis` |
| Automatic remediation | `false` (manual invocation required) |
| S3 report bucket | not configured — recommendations live in tags only, truncated at 256 chars |

---

## Prerequisites

### 1. AWS profile / credentials

Each operator uses their own AWS profile or role. Configure it to point at account `014280747320` in `us-gov-west-1`, then either:

```bash
export AWS_PROFILE=<your-profile-name>
```

or set it as your default profile in `~/.aws/config`. All commands in this runbook assume whatever profile is in scope is the right one — no `--profile` flag is hardcoded.

Verify before proceeding:

```bash
aws sts get-caller-identity
```

You should see account `014280747320` and an ARN in the `aws-us-gov` partition.

### 2. IAM permissions

Your identity must have the operator managed policy (see `operator-policy.txt`) attached. If you see `AccessDenied` on any step, request this policy from your admin.

### 3. Python

These scripts invoke Python. Set the binary name for your system:

```bash
export PY=python3       # Linux/macOS default
# export PY=python      # Windows with Python installed as 'python'
```

### 4. Shell

A bash-compatible shell: Linux/macOS terminal, WSL, or Git Bash on Windows. PowerShell and cmd will not work for the `while` loops.

### 5. Windows CRLF note

Python on Windows emits `\r\n` line endings by default. When piped into `while read -r`, bash keeps the trailing `\r`, silently poisoning every downstream variable. Symptom: SSM executions start with valid IDs but fail internally with "policy not found" errors because the UUID has a trailing `\r`; tag-read loops call `aws iam list-policy-tags` with a polluted ARN and `2>/dev/null` hides the ValidationError.

**The `| tr -d '\r'` lines in Step 3 and Step 5 are defensive, not cruft — do not remove them.** They are no-ops on Linux/macOS (no `\r` to strip) and are the only thing preventing silent failures on Windows.

If you're seeing unexpected empty results, inspect any file written by one of these pipelines:

```bash
cat -A <filename>
```

If you see `^M` anywhere in the output, CRLF pollution has already occurred. Clear the file and re-run with the `tr -d '\r'` guard in place.

---

## Step 1 — Force Config to evaluate the fleet

Config re-evaluates every 24 hours on its own, but you can trigger it immediately:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names automation-iam-wildcard-action-policy
```

**Expected output:** empty response (the API returns no body on success).

Wait 2-3 minutes for the Lambda evaluator to scan every customer-managed IAM policy.

---

## Step 2 — See which policies Config flagged as non-compliant

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name automation-iam-wildcard-action-policy \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[].{ResourceId:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId, Annotation:Annotation}' \
  --output table
```

**Expected output:** a table listing the policy UUIDs (e.g., `ANPAIABCDEF...`) and the wildcard services found in each (e.g., "Contains wildcard action for service(s): s3, ec2"). If the table is empty, either evaluation hasn't finished yet or you genuinely have no wildcard policies — in which case there's nothing to do.

Note: `ResourceId` is a policy UUID, not an ARN. The SSM document accepts both, so you don't need to convert it yourself.

---

## Step 3 — Run `full-analysis` on the top 5 non-compliant policies

This tags each policy with its category (Simple/Moderate/Complex), wildcard services, attachment info, and CloudTrail-derived suggested fixes. Safe — does not modify policy content.

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name automation-iam-wildcard-action-policy \
  --compliance-types NON_COMPLIANT \
  --output json \
  | python -c "import sys,json; [print(r['EvaluationResultIdentifier']['EvaluationResultQualifier']['ResourceId']) for r in json.load(sys.stdin)['EvaluationResults']]" \
  | tr -d '\r' \
  | while read -r pid; do
      [ -z "$pid" ] && continue
      exec_id=$(aws ssm start-automation-execution \
        --document-name automation-iam-wildcard-action-policy \
        --parameters "ResourceId=$pid,AutomationAssumeRole=arn:aws-us-gov:iam::014280747320:role/automation-iam-wildcard-ssm,Action=full-analysis" \
        --query 'AutomationExecutionId' --output text)
      echo "policy=$pid  exec=$exec_id"
    done | tee /tmp/iam-wildcard-runs.txt
```

**Expected output:**

```
policy=ANPAIABCDEF123456789  exec=12345678-1234-1234-1234-123456789012
policy=ANPAIGHIJKL234567890  exec=abcdef01-1234-1234-1234-abcdef012345
policy=ANPAIMNOPQR345678901  exec=98765432-abcd-efgh-ijkl-987654321098
policy=ANPAISTUVWX456789012  exec=11111111-2222-3333-4444-555555555555
policy=ANPAIYZABCD567890123  exec=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
```

Execution IDs are saved to `/tmp/iam-wildcard-runs.txt` for Step 4.

**Variations:**
- Run on all non-compliant policies: remove `| head -5`. Safe up to ~25 concurrent executions per document.
- Run on a single specific policy: replace the pipeline with a direct invocation, passing the policy ARN or UUID as `ResourceId`.

---

## Step 4 — Monitor the SSM executions

Each execution takes 30s-2min depending on CloudTrail lookback and wildcard service count. Check status:

```bash
awk '{print $2}' /tmp/iam-wildcard-runs.txt | sed 's/exec=//' | while read -r eid; do
  status=$(aws ssm get-automation-execution \
    --automation-execution-id "$eid" \
    --query 'AutomationExecution.AutomationExecutionStatus' --output text)
  echo "$eid  $status"
done
```

**Expected output:**

```
12345678-1234-1234-1234-123456789012  Success
abcdef01-1234-1234-1234-abcdef012345  Success
98765432-abcd-efgh-ijkl-987654321098  InProgress
11111111-2222-3333-4444-555555555555  Success
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Success
```

Status values:
- `Success` — done, tags applied, safe to proceed
- `InProgress` — still running, re-run this command in 30-60 seconds
- `Failed` — diagnose with the command below
- `Cancelled` — someone manually stopped it

For any `Failed` execution:

```bash
aws ssm describe-automation-step-executions \
  --automation-execution-id <exec-id> \
  --query 'StepExecutions[?StepStatus==`Failed`].{Step:StepName,Reason:FailureMessage}' \
  --output table
```

Common failure causes: AccessDenied (IAM role missing a permission), throttling on CloudTrail lookup, or the policy was deleted between Config's evaluation and the SSM run.

---

## Step 5 — Read category tags across the fleet

Lists every customer-managed policy that has been analyzed, showing category and wildcard services. Progress is printed to stderr so you can watch; matches accumulate in `/tmp/tag-loop.log` as they're found; final sorted results print to stdout at the end.

Expect roughly 1 second per policy in the fleet. For 400+ policies, budget ~8-12 minutes.

```bash
total=$(aws iam list-policies --scope Local --output json \
  | python -c "import sys,json; print(len(json.load(sys.stdin)['Policies']))")
echo "Checking $total customer-managed policies..." >&2
: > /tmp/tag-loop.log
count=0

aws iam list-policies --scope Local --output json \
  | python -c "import sys,json; [print(p['Arn']) for p in json.load(sys.stdin)['Policies']]" \
  | tr -d '\r' \
  | while read -r arn; do
      [ -z "$arn" ] && continue
      count=$((count + 1))
      echo "[$count/$total] $arn" >&2
      tags=$(aws iam list-policy-tags --policy-arn "$arn" --output json 2>/dev/null) || continue
      [ -z "$tags" ] && continue
      cat=$(echo "$tags"  | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('WildcardCategory',''))")
      svcs=$(echo "$tags" | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('WildcardServices',''))")
      if [ -n "$cat" ]; then
        line="$cat | $svcs | $arn"
        echo "  -> MATCH: $line" >&2
        echo "$line" >> /tmp/tag-loop.log
      fi
    done

echo "" >&2
echo "=== Final results (sorted) ===" >&2
sort /tmp/tag-loop.log
```

**Expected stderr (live progress):**

```
Checking 423 customer-managed policies...
[1/423] arn:aws-us-gov:iam::014280747320:policy/app-parameter-reader
  -> MATCH: Simple | ssm | arn:aws-us-gov:iam::014280747320:policy/app-parameter-reader
[2/423] arn:aws-us-gov:iam::014280747320:policy/monitoring-role-pol
...
```

**Expected stdout (after completion, sorted):**

```
Complex | ssm,s3,ec2,iam,lambda | arn:aws-us-gov:iam::014280747320:policy/legacy-poweruser
Moderate | logs,cloudwatch | arn:aws-us-gov:iam::014280747320:policy/monitoring-role-pol
Simple | ssm | arn:aws-us-gov:iam::014280747320:policy/app-parameter-reader
```

Ctrl-C is safe at any point — the loop is read-only. Partial matches remain in `/tmp/tag-loop.log`.

---

## Step 6 — Pull full remediation details for matched policies

Step 5's output shows category and services but not the actual fix recommendations. This follow-up reads `SuggestedFix`, `AttachedTo`, `LastAccessedServices`, and `LastEvaluated` for each matched policy. Only queries the policies that matched (cheap, a handful of API calls).

```bash
awk -F' \\| ' '{print $NF}' /tmp/tag-loop.log | while read -r arn; do
  [ -z "$arn" ] && continue
  tags=$(aws iam list-policy-tags --policy-arn "$arn" --output json 2>/dev/null) || continue

  cat=$(echo "$tags"       | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('WildcardCategory',''))")
  svcs=$(echo "$tags"      | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('WildcardServices',''))")
  attached=$(echo "$tags"  | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('AttachedTo',''))")
  lastused=$(echo "$tags"  | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('LastAccessedServices',''))")
  fix=$(echo "$tags"       | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('SuggestedFix',''))")
  last_eval=$(echo "$tags" | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('LastEvaluated',''))")

  echo "============================================================"
  echo "Policy:         $arn"
  echo "Category:       $cat"
  echo "Wildcards:      $svcs"
  echo "Attached to:    $attached"
  echo "Last used svcs: $lastused"
  echo "Last evaluated: $last_eval"
  echo "Suggested fix:  $fix"
done
```

**Expected output:**

```
============================================================
Policy:         arn:aws-us-gov:iam::014280747320:policy/app-parameter-reader
Category:       Simple
Wildcards:      ssm
Attached to:    role/lambda-app-execution-role
Last used svcs: ssm,logs
Last evaluated: 2026-04-24T14:32:15Z
Suggested fix:  ssm:GetParameter,ssm:GetParameters,ssm:GetParametersByPath
============================================================
Policy:         arn:aws-us-gov:iam::014280747320:policy/legacy-poweruser
Category:       Complex
Wildcards:      ssm,s3,ec2,iam,lambda
Attached to:    role/shared-services
Last used svcs: s3,ec2,lambda
Last evaluated: 2026-04-24T14:33:01Z
Suggested fix:  s3:[GetObject,ListBucket,PutObject];ec2:[DescribeInstances,Run...[TRUNCATED]
```

`SuggestedFix` is truncated at 256 chars (IAM tag value limit). For full per-service details, use Step 7 or configure `report_s3_bucket` in Terraform.

---

## Step 7 — Pull full untruncated details from SSM execution output

When `SuggestedFix` is truncated, the full recommendation still exists in the SSM execution output for runs you initiated in Step 3.

```bash
awk '{print $2}' /tmp/iam-wildcard-runs.txt | sed 's/exec=//' | while read -r eid; do
  echo "=== $eid ==="
  aws ssm get-automation-execution \
    --automation-execution-id "$eid" \
    --query 'AutomationExecution.Outputs' --output json
done
```

**Expected output:** JSON with per-service suggested replacement actions, confidence flags (`meets_threshold`), and CloudTrail lookback metadata. No truncation.

For deeper forensics on a single execution:

```bash
aws ssm get-automation-execution \
  --automation-execution-id <exec-id> \
  --output json
```

---

## Remediating based on results

| Category | Count typical | Recommended path |
|---|---|---|
| **Simple** (1 wildcard) | Most of the fleet | Review `SuggestedFix` tag. If accurate, run `Action=scope-simple` manually per policy, OR switch the module to `remediation_action = "scope-simple"` for fleet-wide auto-scoping. `scope-simple` is the only mutating action — it creates a new policy version and sets it as default. |
| **Moderate** (2-3 wildcards) | Small minority | Module refuses to auto-scope these. Read the S3 report (if configured) or Step 7 output, apply fixes at source (Terraform/CFN/console), coordinate with the owning team. |
| **Complex** (4+ wildcards) | Rare, high-effort | Architectural review. Consider splitting the policy or exempting with `CrwdRemediatorExempt=true` during a planned restructure. |

### Exempting a policy from remediation

```bash
aws iam tag-policy \
  --policy-arn <POLICY_ARN> \
  --tags Key=CrwdRemediatorExempt,Value=true \
         Key=CrwdRemediatorExemptReason,Value="<justification text>"
```

Both tags are required (the reason is enforced by default). Exempt policies are skipped by `analyze`, `suggest-moderate`, `full-analysis`, and `scope-simple`.

### Rolling back an auto-scoped policy

If `scope-simple` mangled a policy, the previous version is preserved. Roll back:

```bash
# find the previous version
aws iam list-policy-tags --policy-arn <POLICY_ARN> \
  --query "Tags[?Key=='PreviousVersion'].Value" --output text

# restore it
aws iam set-default-policy-version \
  --policy-arn <POLICY_ARN> --version-id <previous-version-id>
```

---

## Troubleshooting

### `AccessDenied` on any step
Your operator managed policy isn't attached or is missing a statement. Check with:
```bash
aws sts get-caller-identity
aws iam simulate-principal-policy \
  --policy-source-arn <your-arn-from-above> \
  --action-names <the-action-that-failed>
```

### "Python was not found" on Windows
The Microsoft Store app-execution alias is intercepting `python3`. Either:
- Disable the alias: Settings → Apps → Advanced app settings → App execution aliases → turn off `python.exe` and `python3.exe`
- Or set `PY=python` if your Python installer created that binary

### `json.decoder.JSONDecodeError: Expecting value`
An upstream AWS call returned empty output (usually hidden by `2>/dev/null`). Remove the redirect temporarily to see the real error:
```bash
aws iam list-policy-tags --policy-arn <arn> --output json
```

### `ValidationError: policyArn ... length less than or equal to 2048`
`aws ... --output text` returned a tab-separated list and the shell `while read` consumed all of it as one value. Always use `--output json` with a Python parser for list iteration in this runbook. The provided commands already do this — the error means you're running an older version.

### No matches in Step 5
Either:
- No policies have been analyzed yet — run Step 3 first
- All analyzed policies have been exempted — check for `CrwdRemediatorExempt=true` tags
- Automatic remediation is off — the Config → SSM wiring exists but won't fire without manual Step 3 invocations

### SSM execution `Failed` with throttling
CloudTrail `LookupEvents` has a low request rate limit. Wait 60 seconds and retry, or stagger executions with a `sleep 5` between invocations in Step 3.

### `/tmp/iam-wildcard-runs.txt` shows only `exec=...` instead of `policy=... exec=...`
Windows CRLF pollution (see Prerequisites section 5). The `policy=` prefix is still in the file bytes, but a trailing `\r` on the policy UUID causes the terminal to render it as overwritten. Confirm with:
```bash
cat -A /tmp/iam-wildcard-runs.txt
```
If you see `^M` between the UUID and `exec=`, CRLF pollution has occurred and your SSM executions likely failed server-side because the polluted UUID couldn't be resolved to a policy. Fix: ensure `| tr -d '\r'` is present after the Python extractor in Step 3, clear stale state (`rm -f /tmp/iam-wildcard-runs.txt /tmp/tag-loop.log`), and re-run from Step 3.

### SSM execution `Failed` with "policy not found" or similar resolution error
Same root cause as the CRLF issue above — the polluted UUID can't be resolved. Same fix.

### Step 5 finds zero matches despite Step 4 showing `Success`
Check Step 3's execution log is clean first:
```bash
cat -A /tmp/iam-wildcard-runs.txt
```
If clean, verify the executions actually wrote tags on one of the policies directly:
```bash
policy_uuid=$(head -1 /tmp/iam-wildcard-runs.txt | awk '{print $1}' | sed 's/policy=//')
arn=$(aws iam list-policies --scope Local --output json \
  | python -c "import sys,json; [print(p['Arn']) for p in json.load(sys.stdin)['Policies'] if p['PolicyId']=='$policy_uuid']")
aws iam list-policy-tags --policy-arn "$arn" --output table
```
If `WildcardCategory` is missing from the table, the SSM doc ran but didn't reach the tagging step — check `aws ssm describe-automation-step-executions` for the execution to see which step failed.

---

## Next steps after initial runthrough

1. **Verify results on a sample.** Pick 2-3 Simple policies, compare `SuggestedFix` against what the owning team actually expects the policy to do.
2. **Consider enabling `automatic_remediation = true`.** With `remediation_action = "full-analysis"`, this is non-mutating — Config will run `full-analysis` on every NON_COMPLIANT policy every 24 hours without Step 3 scripting. Still read-only.
3. **Configure an S3 report bucket** (`report_s3_bucket` in tfvars) for full per-service fix detail instead of the 256-char truncated tags.
4. **Progress toward `scope-simple`.** Once you've validated suggestions for Simple policies, switch `remediation_action = "scope-simple"` to start auto-scoping them fleet-wide. This is the first mutating step; keep `automatic_remediation = false` initially so you run it manually per-policy.
5. **Set up flap monitoring** for externally-managed policies (see module README "Find flapping policies" section).

---

## Appendix — useful ad-hoc queries

### Fleet summary by category

```bash
sort /tmp/tag-loop.log | awk -F' \\| ' '{print $1}' | sort | uniq -c
```

### Find policies without `LastAccessedServices` overlap with `WildcardServices`

(Indicates wildcards that are granted but never exercised — strong signal to remove.)

```bash
awk -F' \\| ' '{print $NF}' /tmp/tag-loop.log | while read -r arn; do
  tags=$(aws iam list-policy-tags --policy-arn "$arn" --output json 2>/dev/null) || continue
  ws=$(echo "$tags"  | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('WildcardServices',''))")
  las=$(echo "$tags" | python -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin).get('Tags',[])}; print(t.get('LastAccessedServices',''))")
  unused=$(python -c "
ws=set('$ws'.split(',')) - {''}
las=set('$las'.split(',')) - {''}
diff=ws - las
print(','.join(sorted(diff)) if diff else '')
")
  [ -n "$unused" ] && echo "UNUSED_WILDCARDS=$unused  $arn"
done
```

### Find currently-flapping policies

```bash
aws iam list-policies --scope Local --query "Policies[].Arn" --output text | tr '\t' '\n' | while read -r arn; do
  last=$(aws iam list-policy-tags --policy-arn "$arn" \
    --query "Tags[?Key=='FlapLastDetected'].Value" --output text 2>/dev/null)
  [ -n "$last" ] && echo "$last $arn"
done | sort -r
```

### Count non-compliant policies

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name automation-iam-wildcard-action-policy \
  --compliance-types NON_COMPLIANT \
  --output json \
  | python -c "import sys,json; print(len(json.load(sys.stdin)['EvaluationResults']))"
```

---

## Version

| Date | Change |
|---|---|
| 2026-04-24 | Initial runbook for deployment with `automatic_remediation = false`, `remediation_action = full-analysis`, no S3 report bucket |
