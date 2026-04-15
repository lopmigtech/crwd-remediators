# iam-wildcard-action-policy — Toggleable Auto-Remediation Design

**Status:** Draft for review
**Target module version:** `iam-wildcard-action-policy/v1.1.0` (minor bump — backwards compatible)
**Date:** 2026-04-15
**Author:** Miguel Lopez

## Context

The `iam-wildcard-action-policy` module today supports a detection-only default and an "auto-analyze" mode that tags policies without modifying them. The `scope-simple` mode (the one that actually rewrites `<service>:*` into a specific action list) can only be triggered by an operator running `aws ssm start-automation-execution` per policy. There is no way to have Config auto-invoke `scope-simple` at scale.

This design adds a toggle that allows operators to configure Config's automatic remediation to run any of the three existing SSM document modes (`analyze`, `scope-simple`, `suggest-moderate`), plus the supporting features needed to make auto-scoping operationally safe at fleet scale:

- A periodic sweep that covers existing resources (not just future changes)
- Flap detection for policies that keep getting reverted by an external source of truth
- Tag-based exemption so resource owners can self-declare break-glass/core-system exceptions
- Optional auto-exempt on flap threshold for environments where detection-only isn't enough

## Goals

1. Let operators enable automatic `scope-simple` (or any other mode) via a single module variable, without custom orchestration.
2. Cover existing (untouched) IAM policies in the account, not just policies modified after deployment.
3. Make conflicts between this module and externally-managed policies (Terraform, CloudFormation, GitOps) visible and operationally actionable.
4. Give resource owners a decentralized escape hatch (a tag) for break-glass/core-system policies that legitimately need wildcard permissions.
5. Preserve the module's safety invariants: dry-run default unchanged, `scope-simple` still skips Moderate/Complex policies, `min_actions_threshold` still gates CloudTrail-sparse policies.

## Non-goals

- Replacing the CloudTrail-based action discovery with IAM Access Analyzer policy generation (evaluated and rejected — see triage notes in conversation log).
- Changing the `analyze` mode's behavior (it remains tag-only, no policy modification).
- Adding a new mode beyond `analyze` / `scope-simple` / `suggest-moderate`.
- Building an SNS/EventBridge alerting pipeline for flap events (punted to a future `v1.2.0`).
- Extending flap detection or tag-based exemption to other remediator modules in the repo (this design ships those mechanisms for this module only; the feedback memory captures the pattern for future authors).

## Design overview

Five coordinated additions:

1. **`remediation_action` variable** wires the SSM `Action` parameter through the remediation configuration instead of hardcoding `"analyze"`.
2. **`evaluation_frequency` variable** adds a `ScheduledNotification` to the Config rule's `source_detail` so it periodically re-evaluates all in-scope IAM policies (covers existing resources plus ongoing drift).
3. **README operator-patterns section** documenting three ways to handle externally-managed policies that conflict with the remediator (fix at source / exclude / accept).
4. **Flap-detection tags** (`FlapDetected`, `FlapCount`, `ScopedDate`, `FlapFirstSeen`) emitted by the SSM document at the end of a successful `scope-simple` run. Detection-only — they do not change remediation behavior.
5. **Tag-based exemption mechanism** read by the SSM document's `CheckExclusion` step — honored when the policy carries `CrwdRemediatorExempt = "true"` with a required reason, plus an optional auto-exempt mode that applies the exemption tag itself after N flap cycles (off by default, opt-in).

The five pieces are independent at the code level but compose into one coherent story: *the module can now run fully automatic at fleet scale, surfaces conflicts with external managers, and gives both platform teams and resource owners graduated levers to pause enforcement on specific policies.*

## Component design

### 1. `remediation_action` variable

**New variable:**

```hcl
variable "remediation_action" {
  type        = string
  default     = "analyze"
  description = "SSM document Action parameter that Config invokes when automatic_remediation = true. Valid: 'analyze' (tag-only), 'scope-simple' (auto-rewrite single-wildcard policies), 'suggest-moderate' (generate suggestions for multi-wildcard policies)."
  validation {
    condition     = contains(["analyze", "scope-simple", "suggest-moderate"], var.remediation_action)
    error_message = "remediation_action must be one of: analyze, scope-simple, suggest-moderate."
  }
}
```

**Change in `main.tf`:** the `Action` parameter in `aws_config_remediation_configuration.this` changes from `static_value = "analyze"` to `static_value = var.remediation_action`.

**Default stays `"analyze"`** so existing v1.0.0 users upgrading to v1.1.0 see no behavior change.

### 2. `evaluation_frequency` variable (scheduled sweep)

**New variable:**

```hcl
variable "evaluation_frequency" {
  type        = string
  default     = "TwentyFour_Hours"
  description = "How often Config re-evaluates all in-scope IAM policies. Valid AWS Config MaximumExecutionFrequency values, or 'Off' to disable scheduled evaluation (change-triggered only)."
  validation {
    condition     = contains(["Off", "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be one of: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}
```

**Change in `main.tf`:** a third `source_detail` block is added conditionally using `dynamic "source_detail"`:

```hcl
dynamic "source_detail" {
  for_each = var.evaluation_frequency == "Off" ? [] : [1]
  content {
    message_type                = "ScheduledNotification"
    maximum_execution_frequency = var.evaluation_frequency
  }
}
```

**Default `TwentyFour_Hours`** balances coverage against cost ($30/month at 1,000 policies — 99% of total cost). Operators can set `"Off"` to revert to change-only evaluation or increase frequency for more active environments.

**Cost implications documented in the README** (same table as in the brainstorming conversation).

### 3. README operator-patterns section

**New section in `modules/iam-wildcard-action-policy/README.md`** titled **"When policies are externally managed"**, inserted between the existing "Per-resource exclusion (Tier 1)" and "Rollback procedure" sections. Covers three patterns:

| Pattern | When to use | How |
|---|---|---|
| **Fix at source** | The policy is Terraform/CFN-managed and the owning team can update it | Run `Action=suggest-moderate` or `Action=analyze` to discover the action list. Update the source-of-truth with specific actions. Remove the wildcard at the source |
| **Exclude, then fix at source** | The fix requires coordination (change windows, approvals, cross-team) | Add the ARN to `excluded_resource_ids` OR tag the policy with `CrwdRemediatorExempt = true` and `CrwdRemediatorExemptReason = <justification>`. Resume remediation by removing the entry/tag after the source-of-truth fix |
| **Accept the flap** | Policy is test-only, ephemeral, or the flap is a forcing function | Do nothing. The `FlapDetected = true` tag and daily CloudTrail noise surface the problem to whoever owns the policy |

Includes CLI snippets for each pattern, a decision tree (flap detected → choose pattern), and a "how to find flapping policies" query:

```bash
aws iam list-policies --scope Local --query "Policies[].Arn" --output text | while read arn; do
  flap=$(aws iam list-policy-tags --policy-arn "$arn" \
    --query "Tags[?Key=='FlapDetected'].Value" --output text 2>/dev/null)
  [ "$flap" = "true" ] && echo "$arn"
done
```

### 4. Flap-detection tags

**Emitted by the SSM document at the end of a successful `scope-simple` run** (after `iam:CreatePolicyVersion`, alongside the existing `PreviousVersion` / `RemovedWildcard` / `ReplacedWith` / `ScopedDate` tags):

| Tag | Set when | Value |
|---|---|---|
| `FlapCount` | Always, on every `scope-simple` success | Integer string; increments on each successive scope within the flap window |
| `FlapFirstSeen` | Set on the first flap (FlapCount transitions from 0 → 2) | ISO-8601 timestamp |
| `FlapDetected` | Set to `"true"` when the previous `ScopedDate` is within `flap_window_days` of the current run | `"true"` or absent |
| `FlapLastDetected` | Updated on each flap occurrence | ISO-8601 timestamp |

**Flap window variable:**

```hcl
variable "flap_window_days" {
  type        = number
  default     = 7
  description = "Time window within which successive scope-simple runs on the same policy are considered a flap. Used only for FlapDetected tagging."
  validation {
    condition     = var.flap_window_days >= 1 && var.flap_window_days <= 90
    error_message = "flap_window_days must be between 1 and 90."
  }
}
```

**Detection logic (pseudocode added to SSM document's `scope-simple` branch, after `iam:CreatePolicyVersion` succeeds):**

```python
prior_scoped_date = tag_map.get("ScopedDate")  # ISO-8601 from prior successful scope
flap_count = int(tag_map.get("FlapCount", "0"))

if prior_scoped_date:
    prior_dt = datetime.datetime.strptime(prior_scoped_date, "%Y-%m-%dT%H:%M:%SZ")
    delta_days = (datetime.datetime.utcnow() - prior_dt).days
    if delta_days <= flap_window_days:
        flap_count += 1
        new_tags.extend([
            {"Key": "FlapCount", "Value": str(flap_count)},
            {"Key": "FlapDetected", "Value": "true"},
            {"Key": "FlapLastDetected", "Value": timestamp},
        ])
        if flap_count == 2:  # first flap
            new_tags.append({"Key": "FlapFirstSeen", "Value": prior_scoped_date})
    else:
        # Outside the window — reset flap state
        flap_count = 1
        new_tags.append({"Key": "FlapCount", "Value": "1"})
        # FlapDetected is NOT re-applied; it persists from prior flap episodes as audit history
else:
    flap_count = 1
    new_tags.append({"Key": "FlapCount", "Value": "1"})
```

**Explicitly NOT a short-circuit.** Remediation always proceeds; the tags are detection-only. This is a deliberate design choice to preserve the invariant that the module never leaves a known-non-compliant resource in a known-non-compliant state without telling somebody. The visibility lever is the tag; the control lever is exclusion (list or tag).

### 5. Tag-based exemption + auto-exempt on flap

**Exemption tag schema:**

| Tag | Written by | Read by | Purpose |
|---|---|---|---|
| `CrwdRemediatorExempt` | Human operator OR module (auto-exempt mode) | SSM `CheckExclusion` step | Gate — value `"true"` indicates exemption |
| `CrwdRemediatorExemptReason` | Human operator OR module (auto-exempt mode) | SSM `CheckExclusion` step | Required justification; empty/missing ignores the exemption when `require_exemption_reason = true` |
| `CrwdRemediatorExemptExpiry` | Module (auto-exempt mode) | SSM `CheckExclusion` step | ISO-8601 date; exemption ignored if in the past |
| `CrwdAutoExempted` | Module (auto-exempt mode) | Operators / CrowdStrike filters | Marks auto-applied exemptions so they can be distinguished from human-applied ones in audits |

**Human-applied exemptions have no expiry** (the operator has made an explicit decision; they retain control of revocation). **Auto-applied exemptions always have an expiry** (the module unilaterally paused enforcement; the expiry forces human review).

**New variables:**

```hcl
variable "tag_based_exemption_enabled" {
  type        = bool
  default     = true   # Default-on per design decision; operators pre-tag known exemptions before apply
  description = "If true, the SSM document's CheckExclusion step checks policy tags for CrwdRemediatorExempt and skips remediation when present and valid."
}

variable "exemption_tag_key" {
  type        = string
  default     = "CrwdRemediatorExempt"
  description = "Tag key used to exempt a policy from remediation. Value 'true' triggers skip logic."
}

variable "require_exemption_reason" {
  type        = bool
  default     = true
  description = "If true, the exemption tag is only honored when a companion CrwdRemediatorExemptReason tag contains a non-empty string. Bare boolean exemptions are ignored (and logged) when this is true."
}

variable "auto_exempt_on_flap_enabled" {
  type        = bool
  default     = false  # Opt-in; module self-modifying behavior should not be a default
  description = "If true, the SSM document self-applies CrwdRemediatorExempt=true on policies whose FlapCount reaches auto_exempt_flap_threshold. Requires tag_based_exemption_enabled = true."
}

variable "auto_exempt_flap_threshold" {
  type        = number
  default     = 3
  description = "Number of flap cycles that triggers auto-exemption. Only applies when auto_exempt_on_flap_enabled = true."
  validation {
    condition     = var.auto_exempt_flap_threshold >= 2 && var.auto_exempt_flap_threshold <= 20
    error_message = "auto_exempt_flap_threshold must be between 2 and 20."
  }
}

variable "auto_exempt_duration_days" {
  type        = number
  default     = 30
  description = "Days until an auto-applied exemption expires. After expiry, the exemption tag is ignored and remediation resumes. Set low to force quick human review."
  validation {
    condition     = var.auto_exempt_duration_days >= 1 && var.auto_exempt_duration_days <= 365
    error_message = "auto_exempt_duration_days must be between 1 and 365."
  }
}
```

**Cross-variable validation (precondition in `main.tf`):**

```hcl
resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = !var.auto_exempt_on_flap_enabled || var.tag_based_exemption_enabled
      error_message = "auto_exempt_on_flap_enabled requires tag_based_exemption_enabled = true."
    }
  }
}
```

**Updated `CheckExclusion` logic** (full pseudocode in the conversation log above; summarized here):

1. Existing check: if `resource_id in excluded_resource_ids` → skip
2. If tag-based exemption enabled:
   - `iam.list_policy_tags(PolicyArn=resource_id)`
   - If exemption tag value is `"true"`:
     - If reason required and missing/empty → log warning, proceed with remediation (fail-loud)
     - If expiry present and in the past → log "exemption expired", proceed with remediation
     - Otherwise → skip with reason string from tag
   - If tag lookup raises an exception → log warning, proceed with remediation (fail-closed on transient API errors; the goal is to NOT silently skip on error)
3. Otherwise → proceed with remediation

**Auto-exempt write logic (end of `scope-simple` success block):**

After the `FlapCount` tag is updated, if `auto_exempt_on_flap_enabled` and `flap_count >= auto_exempt_flap_threshold`:

```python
expiry_date = (datetime.datetime.utcnow() + datetime.timedelta(days=auto_exempt_duration_days)).strftime("%Y-%m-%d")
new_tags.extend([
    {"Key": "CrwdRemediatorExempt", "Value": "true"},
    {"Key": "CrwdRemediatorExemptReason", "Value": f"auto-applied after {flap_count} flap cycles within {flap_window_days}d window"},
    {"Key": "CrwdRemediatorExemptExpiry", "Value": expiry_date},
    {"Key": "CrwdAutoExempted", "Value": "true"},
])
```

## Parameter wiring (SSM ⇄ remediation config)

The SSM document needs five new input parameters to support this design:

| Parameter | Type | Source | Purpose |
|---|---|---|---|
| `TagBasedExemptionEnabled` | String (`"true"` / `"false"`) | `var.tag_based_exemption_enabled` via remediation config `static_value` | Toggle CheckExclusion tag logic |
| `ExemptionTagKey` | String | `var.exemption_tag_key` | Tag key to read |
| `RequireExemptionReason` | String (`"true"` / `"false"`) | `var.require_exemption_reason` | Whether bare boolean bypasses count |
| `AutoExemptEnabled` | String (`"true"` / `"false"`) | `var.auto_exempt_on_flap_enabled` | Toggle auto-exempt write in scope-simple |
| `AutoExemptFlapThreshold` | String | `tostring(var.auto_exempt_flap_threshold)` | Numeric threshold |
| `AutoExemptDurationDays` | String | `tostring(var.auto_exempt_duration_days)` | Expiry window |
| `FlapWindowDays` | String | `tostring(var.flap_window_days)` | Detection window |

SSM Automation parameters are typed — numbers are passed as strings and parsed in the handler (matches existing `CloudTrailLookbackDays` pattern at `ssm/document.yaml:23-30`).

## Safety analysis

Invariants that must remain true after this change:

| Invariant | How this design preserves it |
|---|---|
| `automatic_remediation = false` remains the module default (Rule 8) | Unchanged — `remediation_action` only takes effect when `automatic_remediation = true` |
| `scope-simple` never modifies Moderate or Complex policies | Unchanged — the `if category != "Simple"` check at `ssm/document.yaml:239` is untouched |
| `min_actions_threshold` gates CloudTrail-sparse policies | Unchanged |
| Detection is stateless — no tag can silently mask a wildcard | Preserved. The new `CheckExclusion` tag logic uses tag values but: (a) requires justification, (b) honors expiry on auto-applied exemptions, (c) fails-open-to-remediation on API errors or invalid expiry format |
| The module never leaves a known-non-compliant resource in an unreported state | Preserved. Exempted policies remain flagged NON_COMPLIANT by Config (the Lambda evaluator doesn't check tags); the exemption only stops remediation, not detection |
| Rollback remains one CLI call | Unchanged — `PreviousVersion` tag still written |

**Attack surface additions:**

- An attacker who can write IAM tags on a policy can exempt themselves from remediation. Mitigations: (a) `iam:TagPolicy` is privileged in most environments; (b) CrowdStrike monitors tag changes; (c) `require_exemption_reason` makes silent exemption harder.
- An attacker who can control the `CrwdRemediatorExemptExpiry` value can keep an exemption open indefinitely by setting a far-future date. Acceptable — same attack surface as `iam:TagPolicy` itself.
- An attacker who can force flap-loop conditions (revert policies quickly) could trigger auto-exempt and permanently disable remediation on a specific policy for 30 days (when `auto_exempt_on_flap_enabled = true`). Acceptable — requires `iam:CreatePolicyVersion` + `iam:SetDefaultPolicyVersion`, which are privileged.

## Testing plan

**Unit-level (plan-mode):** extend `tests/plan.tftest.hcl` to cover the new variables:

1. `remediation_action` defaults to `"analyze"` → remediation config `parameter[Action].static_value == "analyze"`
2. `remediation_action = "scope-simple"` → static_value changes accordingly
3. Invalid `remediation_action` value → plan fails with validation error
4. `evaluation_frequency = "Off"` → Config rule has 2 source_detail blocks (no scheduled)
5. `evaluation_frequency = "TwentyFour_Hours"` (default) → Config rule has 3 source_detail blocks, one with `message_type = "ScheduledNotification"` and `maximum_execution_frequency = "TwentyFour_Hours"`
6. `tag_based_exemption_enabled = true` (default) → TagBasedExemptionEnabled parameter on remediation config is `"true"`
7. `auto_exempt_on_flap_enabled = true` with `tag_based_exemption_enabled = false` → precondition error (validation ordering check)

This brings the plan-mode test count from 7 to ~14 assertions (well over Gate 16's minimum of 5).

**Integration-level (apply-mode, optional):** a new `tests/apply.tftest.hcl` that:

1. Deploys the module with `remediation_action = "scope-simple"` and a mock policy with `ssm:*`
2. Manually triggers the SSM doc with `Action=scope-simple`, verifies the policy is scoped
3. Reverts the policy to `ssm:*`, triggers again, verifies `FlapCount` tag increments
4. Adds `CrwdRemediatorExempt = true` + reason tag, triggers again, verifies SSM returns `"skip"`
5. Removes the reason, triggers again, verifies SSM proceeds despite the boolean tag (fail-loud)

Apply-mode tests require live AWS and are optional per Rule 7. They'd live in the same pattern but aren't required for the v1.1.0 tag.

**Manual validation checklist** (added to README's "How to test this module" section):

1. Deploy with defaults (`automatic_remediation = false`) → verify no behavior change
2. Set `automatic_remediation = true`, `remediation_action = "scope-simple"` → verify scheduled sweep runs in 24h
3. Tag a test policy with `CrwdRemediatorExempt = true` + reason → verify it's skipped
4. Remove the reason → verify SSM proceeds (fail-loud logging visible in SSM execution output)
5. Create flap conditions → verify `FlapCount` / `FlapDetected` tags appear
6. Enable `auto_exempt_on_flap_enabled`, continue flap → verify auto-exempt tags applied at threshold, expire after N days

## File change summary

| File | Change |
|---|---|
| `variables.tf` | Add 9 new variables (`remediation_action`, `evaluation_frequency`, `flap_window_days`, `tag_based_exemption_enabled`, `exemption_tag_key`, `require_exemption_reason`, `auto_exempt_on_flap_enabled`, `auto_exempt_flap_threshold`, `auto_exempt_duration_days`) |
| `main.tf` | Change `Action` static_value to reference `var.remediation_action`; add 7 new parameter blocks to remediation config; add dynamic `source_detail` for scheduled notification; add `terraform_data` precondition resource |
| `ssm/document.yaml` | Extend `CheckExclusion` step with tag-reading logic; add flap-detection logic to `scope-simple` branch; add auto-exempt write logic to `scope-simple` branch; add 7 new parameters to document's parameter block |
| `README.md` | Add "When policies are externally managed" section; document new variables in Inputs reference table; update quick-start guide to lead with "tag break-glass policies before apply"; document flap-detection tag schema; document exemption tag schema |
| `examples/basic/main.tf` | Add pass-through for new variables (all optional, defaults carried from module) |
| `examples/basic/variables.tf` | Add new variable declarations with defaults |
| `examples/basic/terraform.tfvars.example` | Add commented examples for new variables |
| `tests/plan.tftest.hcl` | Add ~7 new assertions covering new variable wiring |
| `CHANGELOG.md` | Add `## [1.1.0] — 2026-04-15` entry with "Added" section for the five features |
| `outputs.tf` | No changes required |
| `versions.tf` | No changes required |
| `data.tf` | No changes required |
| `lambda/handler.py` | No changes required (evaluator logic is untouched — detection stays stateless) |

## Rollout plan

Because all new variables have defaults that match v1.0.0 behavior:

- `remediation_action` default `"analyze"` = same as hardcoded v1.0.0 behavior
- `evaluation_frequency` default `"TwentyFour_Hours"` = **one behavior delta** vs v1.0.0 (adds scheduled sweep)
- `tag_based_exemption_enabled` default `true` = **one behavior delta** vs v1.0.0 (tag-based exemption becomes active)
- All other new variables are no-ops when their gating variable is off

The two deltas are documented in the CHANGELOG's "Changed" section. Operators upgrading from v1.0.0 will see:

1. A new scheduled Config evaluation firing every 24 hours (~$30/month for 1,000 policies)
2. Any policy that happened to be tagged with `CrwdRemediatorExempt = true` + valid reason will now be skipped

Both deltas are opt-out (`evaluation_frequency = "Off"`, `tag_based_exemption_enabled = false`) but default-on because they match the expected production workflow.

**Tag cleanup note for upgraders:** if v1.0.0 was deployed and operators never used IAM tags with the key `CrwdRemediatorExempt`, the upgrade is a no-op for exemption behavior. If those tags DO exist from unrelated use, the upgrade will start honoring them — operators should audit existing tag usage before upgrading.

## Version bump

`iam-wildcard-action-policy/v1.1.0` — minor version, backwards compatible (all new variables have defaults).

## Open questions

1. **Should `FlapDetected` persist indefinitely or reset after N successful non-flap cycles?** Current design: persists as audit history (operators can see "this policy flapped at some point in the past"). Alternative: reset after e.g., 30 days of stable non-flap behavior.
   - *My lean: persist. Audit value outweighs tag cleanliness.*

2. **Should the `CrwdAutoExempted` tag be removed when auto-exemption expires?** Current design: tag persists. Alternative: SSM doc removes it on next evaluation after expiry.
   - *My lean: persist, for the same audit reason as above.*

3. **Should the precondition check (auto-exempt requires tag-based-exemption) be a Terraform precondition or a runtime check in the SSM doc?** Current design: Terraform precondition (fails at plan).
   - *My lean: keep as Terraform precondition — plan-time failures are cheaper and more obvious than runtime.*

4. **CHANGELOG entry date.** Design drafted 2026-04-15. If implementation spans multiple days, should the CHANGELOG reflect implementation completion date or design date?
   - *My lean: the date the v1.1.0 tag is cut.*

None of these are blockers — defaults are chosen and the questions can be settled during implementation or review.
