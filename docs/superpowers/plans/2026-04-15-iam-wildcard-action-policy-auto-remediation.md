# iam-wildcard-action-policy v1.1.0 — Auto-Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add toggleable auto-remediation to the `iam-wildcard-action-policy` module via five coordinated features: operator-selectable remediation action, periodic Config evaluation, flap-detection tagging, tag-based exemption, and opt-in auto-exempt on flap threshold.

**Architecture:** Backwards-compatible minor-version bump. New behavior is gated behind variables with defaults that preserve v1.0.0 behavior on two axes (remediation action, exemption mechanism fields) and introduces two intentional behavior deltas (scheduled Config evaluation at 24h, tag-based exemption default-on). Detection logic remains stateless in the Lambda evaluator; exemption state lives in IAM policy tags read by the SSM document's `CheckExclusion` step.

**Tech Stack:** Terraform (HCL, `~> 5.0` AWS provider), AWS Config custom Lambda rules, AWS SSM Automation documents (YAML + Python inline via `aws:executeScript`), plan-mode `terraform test` assertions.

**Spec:** `docs/superpowers/specs/2026-04-15-iam-wildcard-action-policy-auto-remediation-design.md`

**Working directory for all commands:** `/home/mlopez/crwd-remediators`. All paths are absolute for clarity.

---

## File inventory

| File | Change type | What gets touched |
|---|---|---|
| `modules/iam-wildcard-action-policy/variables.tf` | Modify | Append 9 new variables |
| `modules/iam-wildcard-action-policy/main.tf` | Modify | (a) Change `Action` parameter's `static_value`; (b) add `dynamic "source_detail"` for scheduled notification; (c) add 7 new parameter blocks to remediation config; (d) add `terraform_data` precondition resource |
| `modules/iam-wildcard-action-policy/ssm/document.yaml` | Modify | (a) Add 7 new parameters to document parameter block; (b) extend `CheckExclusion` step with tag-reading logic; (c) add flap detection + auto-exempt write in `scope-simple` branch |
| `modules/iam-wildcard-action-policy/README.md` | Modify | (a) Add "When policies are externally managed" section; (b) update Inputs reference table; (c) update quick-start to lead with pre-apply tagging; (d) document flap/exemption tag schemas |
| `modules/iam-wildcard-action-policy/examples/basic/main.tf` | Modify | Pass-through new variables |
| `modules/iam-wildcard-action-policy/examples/basic/variables.tf` | Modify | Declare new variables |
| `modules/iam-wildcard-action-policy/examples/basic/terraform.tfvars.example` | Modify | Commented examples for new variables |
| `modules/iam-wildcard-action-policy/tests/plan.tftest.hcl` | Modify | Add run blocks / assertions for each new variable's wiring |
| `modules/iam-wildcard-action-policy/CHANGELOG.md` | Modify | Add `## [1.1.0] — 2026-04-15` entry |

**Files that DO NOT change:** `outputs.tf`, `versions.tf`, `data.tf`, `lambda/handler.py`, `lambda/requirements.txt`.

**Git hygiene:** every `git add` stages files by explicit path. Do not run `git add -A` or `git add .` — the repo has unrelated untracked directories (`deployments/dynamodb-test/`, `deployments/iam-test/`, `deployments/test-us-east-1/tfplan`) that must not be swept into commits.

---

## Task 1: Add `remediation_action` variable

**Files:**
- Modify: `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/variables.tf` (append)
- Modify: `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/main.tf` (line ~287)
- Modify: `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/tests/plan.tftest.hcl` (append assertion)

- [ ] **Step 1: Write the failing test**

Append to `tests/plan.tftest.hcl` inside the existing `run "plan_resources"` block (after the last assertion, before the closing `}`):

```hcl
  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "Action"][0] == "analyze"
    error_message = "Action parameter must default to 'analyze' (dry-run-safe)"
  }
```

- [ ] **Step 2: Run the test; verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`

Expected: the new assertion passes today (because the value is hardcoded `"analyze"`), but we want to make sure the assertion wiring is correct before we change the value. Verify all 8 assertions pass. If not, fix the assertion expression before continuing.

- [ ] **Step 3: Add `remediation_action` variable to `variables.tf`**

Append to the end of `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/variables.tf`:

```hcl
variable "remediation_action" {
  type        = string
  description = "SSM document Action parameter that Config invokes when automatic_remediation = true. Valid: 'analyze' (tag-only), 'scope-simple' (auto-rewrite single-wildcard policies), 'suggest-moderate' (generate suggestions for multi-wildcard policies)."
  default     = "analyze"
  validation {
    condition     = contains(["analyze", "scope-simple", "suggest-moderate"], var.remediation_action)
    error_message = "remediation_action must be one of: analyze, scope-simple, suggest-moderate."
  }
}
```

- [ ] **Step 4: Wire the variable into `main.tf`**

In `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/main.tf`, locate the `Action` parameter block inside `resource "aws_config_remediation_configuration" "this"` (around line 286-289):

```hcl
  parameter {
    name         = "Action"
    static_value = "analyze"
  }
```

Change to:

```hcl
  parameter {
    name         = "Action"
    static_value = var.remediation_action
  }
```

- [ ] **Step 5: Add a validation test for invalid values**

Append a new `run` block to `tests/plan.tftest.hcl`:

```hcl
run "invalid_remediation_action_rejected" {
  command = plan

  variables {
    name_prefix        = "test"
    remediation_action = "delete-everything"
  }

  expect_failures = [
    var.remediation_action,
  ]
}
```

- [ ] **Step 6: Run tests; verify all pass**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`

Expected output: 2 runs, all pass. The validation test should successfully confirm that invalid values are rejected.

- [ ] **Step 7: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/variables.tf \
        modules/iam-wildcard-action-policy/main.tf \
        modules/iam-wildcard-action-policy/tests/plan.tftest.hcl
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): add remediation_action variable

Wires the SSM document's Action parameter through a module variable
instead of hardcoding "analyze". Enables operators to configure Config
auto-remediation to run scope-simple or suggest-moderate.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `evaluation_frequency` variable (scheduled sweep)

**Files:**
- Modify: `variables.tf` (append)
- Modify: `main.tf` (inside `resource "aws_config_config_rule" "this"` source block, around line 113-123)
- Modify: `tests/plan.tftest.hcl` (append run blocks)

- [ ] **Step 1: Write the failing test**

Append a new `run` block to `tests/plan.tftest.hcl` after the `run "plan_resources"` block:

```hcl
run "scheduled_notification_enabled_by_default" {
  command = plan

  variables {
    name_prefix = "test"
  }

  assert {
    condition     = length([for sd in aws_config_config_rule.this.source[0].source_detail : sd if sd.message_type == "ScheduledNotification"]) == 1
    error_message = "Config rule must have exactly one ScheduledNotification source_detail when evaluation_frequency != 'Off'"
  }

  assert {
    condition     = [for sd in aws_config_config_rule.this.source[0].source_detail : sd.maximum_execution_frequency if sd.message_type == "ScheduledNotification"][0] == "TwentyFour_Hours"
    error_message = "Default evaluation_frequency must be TwentyFour_Hours"
  }
}

run "scheduled_notification_disabled_when_off" {
  command = plan

  variables {
    name_prefix          = "test"
    evaluation_frequency = "Off"
  }

  assert {
    condition     = length([for sd in aws_config_config_rule.this.source[0].source_detail : sd if sd.message_type == "ScheduledNotification"]) == 0
    error_message = "Config rule must not have a ScheduledNotification source_detail when evaluation_frequency = 'Off'"
  }
}
```

- [ ] **Step 2: Run tests; verify failure**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`

Expected: the two new run blocks fail — specifically, the default-case test will fail because there is no ScheduledNotification source_detail yet. That's the intended failing state. Existing assertions should still pass.

- [ ] **Step 3: Add `evaluation_frequency` variable**

Append to `variables.tf`:

```hcl
variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all in-scope IAM policies. Valid AWS Config MaximumExecutionFrequency values, or 'Off' to disable scheduled evaluation (change-triggered only)."
  default     = "TwentyFour_Hours"
  validation {
    condition     = contains(["Off", "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be one of: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}
```

- [ ] **Step 4: Add the dynamic source_detail block in `main.tf`**

In `main.tf`, locate the `source` block inside `aws_config_config_rule.this` (around line 113-123):

```hcl
  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.rule_evaluator.arn

    source_detail {
      message_type = "ConfigurationItemChangeNotification"
    }
    source_detail {
      message_type = "OversizedConfigurationItemChangeNotification"
    }
  }
```

Change to:

```hcl
  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.rule_evaluator.arn

    source_detail {
      message_type = "ConfigurationItemChangeNotification"
    }
    source_detail {
      message_type = "OversizedConfigurationItemChangeNotification"
    }

    dynamic "source_detail" {
      for_each = var.evaluation_frequency == "Off" ? [] : [1]
      content {
        message_type                = "ScheduledNotification"
        maximum_execution_frequency = var.evaluation_frequency
      }
    }
  }
```

- [ ] **Step 5: Run tests; verify all pass**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`

Expected: all run blocks pass.

- [ ] **Step 6: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/variables.tf \
        modules/iam-wildcard-action-policy/main.tf \
        modules/iam-wildcard-action-policy/tests/plan.tftest.hcl
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): add evaluation_frequency variable

Adds a ScheduledNotification source_detail to the Config rule so it
periodically re-evaluates all in-scope IAM policies. Default is
TwentyFour_Hours; "Off" disables scheduled evaluation (change-triggered
only, matching v1.0.0 behavior).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add flap-detection variable and SSM parameter wiring

This task adds the Terraform-side plumbing for flap detection. The SSM YAML logic follows in the same task's SSM step.

**Files:**
- Modify: `variables.tf` (append)
- Modify: `main.tf` (remediation config parameters — add one new `parameter` block)
- Modify: `ssm/document.yaml` (parameter block at top + `scope-simple` branch)
- Modify: `tests/plan.tftest.hcl` (append assertion)

- [ ] **Step 1: Write the failing test**

Append to the `run "plan_resources"` block in `tests/plan.tftest.hcl`:

```hcl
  assert {
    condition     = length([for p in aws_config_remediation_configuration.this.parameter : p if p.name == "FlapWindowDays"]) == 1
    error_message = "Remediation config must pass FlapWindowDays parameter to SSM document"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "FlapWindowDays"][0] == "7"
    error_message = "Default flap_window_days must be 7"
  }
```

- [ ] **Step 2: Run test; verify failure**

Run: `terraform test`
Expected: the two new assertions fail (no such parameter exists yet).

- [ ] **Step 3: Add the variable**

Append to `variables.tf`:

```hcl
variable "flap_window_days" {
  type        = number
  description = "Time window within which successive scope-simple runs on the same policy are considered a flap. Used only for FlapDetected tagging; does not change remediation behavior."
  default     = 7
  validation {
    condition     = var.flap_window_days >= 1 && var.flap_window_days <= 90
    error_message = "flap_window_days must be between 1 and 90."
  }
}
```

- [ ] **Step 4: Add the SSM parameter in the remediation config**

In `main.tf`, inside `resource "aws_config_remediation_configuration" "this"`, append a new `parameter` block after the existing `ReportS3Bucket` parameter block (around line 303):

```hcl
  parameter {
    name         = "FlapWindowDays"
    static_value = tostring(var.flap_window_days)
  }
```

- [ ] **Step 5: Add the parameter to the SSM document's parameter block**

In `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/ssm/document.yaml`, locate the `parameters:` section (starting at line 4). After the existing `ReportS3Bucket` parameter (ends around line 34), insert:

```yaml
  FlapWindowDays:
    type: String
    default: "7"
    description: "Days within which successive scope-simple runs on the same policy are tagged as a flap"
```

- [ ] **Step 6: Add flap-detection Python logic to scope-simple branch**

In `ssm/document.yaml`, locate the scope-simple branch's tag-write block (around line 305-320 — the `iam.tag_policy` call after `create_policy_version`). Just BEFORE the existing `iam.tag_policy(...)` call, insert the flap-detection logic:

```python
                # Flap detection: compare prior ScopedDate to now
                prior_scoped_date = None
                try:
                    existing_tags_resp = iam.list_policy_tags(PolicyArn=policy_arn)
                    existing_tag_map = {t["Key"]: t["Value"] for t in existing_tags_resp.get("Tags", [])}
                    prior_scoped_date = existing_tag_map.get("ScopedDate")
                except Exception:
                    existing_tag_map = {}

                flap_window_days = int(events.get("FlapWindowDays", "7"))
                flap_count = int(existing_tag_map.get("FlapCount", "0"))
                flap_tags = []
                if prior_scoped_date:
                    try:
                        prior_dt = datetime.datetime.strptime(prior_scoped_date, "%Y-%m-%dT%H:%M:%SZ")
                        delta_days = (datetime.datetime.utcnow() - prior_dt).days
                        if delta_days <= flap_window_days:
                            flap_count += 1
                            flap_tags.extend([
                                {"Key": "FlapCount", "Value": str(flap_count)},
                                {"Key": "FlapDetected", "Value": "true"},
                                {"Key": "FlapLastDetected", "Value": timestamp},
                            ])
                            if flap_count == 2:
                                flap_tags.append({"Key": "FlapFirstSeen", "Value": prior_scoped_date})
                        else:
                            flap_count = 1
                            flap_tags.append({"Key": "FlapCount", "Value": "1"})
                    except ValueError:
                        flap_count = 1
                        flap_tags.append({"Key": "FlapCount", "Value": "1"})
                else:
                    flap_count = 1
                    flap_tags.append({"Key": "FlapCount", "Value": "1"})
```

Then extend the existing `iam.tag_policy` call to include `flap_tags`. The existing block is:

```python
                iam.tag_policy(
                    PolicyArn=policy_arn,
                    Tags=[
                        {"Key": "CrwdAutoScoped", "Value": "true"},
                        {"Key": "PreviousVersion", "Value": default_version_id},
                        {
                            "Key": "RemovedWildcard",
                            "Value": f"{wildcard_service}:wildcard",
                        },
                        {
                            "Key": "ReplacedWith",
                            "Value": "+".join(discovered)[:256],
                        },
                        {"Key": "ScopedDate", "Value": timestamp},
                    ],
                )
```

Change to:

```python
                iam.tag_policy(
                    PolicyArn=policy_arn,
                    Tags=[
                        {"Key": "CrwdAutoScoped", "Value": "true"},
                        {"Key": "PreviousVersion", "Value": default_version_id},
                        {
                            "Key": "RemovedWildcard",
                            "Value": f"{wildcard_service}:wildcard",
                        },
                        {
                            "Key": "ReplacedWith",
                            "Value": "+".join(discovered)[:256],
                        },
                        {"Key": "ScopedDate", "Value": timestamp},
                    ] + flap_tags,
                )
```

- [ ] **Step 7: Add the parameter to the script's InputPayload**

In `ssm/document.yaml`, locate the `InputPayload:` block for `ReadPolicyAndAnalyze` (around line 389-394). Append a new key:

```yaml
        FlapWindowDays: "{{ FlapWindowDays }}"
```

The full updated `InputPayload` block should read:

```yaml
      InputPayload:
        ResourceId: "{{ ResourceId }}"
        Action: "{{ Action }}"
        CloudTrailLookbackDays: "{{ CloudTrailLookbackDays }}"
        MinActionsThreshold: "{{ MinActionsThreshold }}"
        ReportS3Bucket: "{{ ReportS3Bucket }}"
        FlapWindowDays: "{{ FlapWindowDays }}"
```

- [ ] **Step 8: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/ssm/document.yaml'))"`

Expected: no output (clean parse). If YAML errors, fix indentation.

- [ ] **Step 9: Run Terraform tests; verify all pass**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`
Expected: all assertions pass.

- [ ] **Step 10: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/variables.tf \
        modules/iam-wildcard-action-policy/main.tf \
        modules/iam-wildcard-action-policy/ssm/document.yaml \
        modules/iam-wildcard-action-policy/tests/plan.tftest.hcl
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): add flap-detection tagging

Emits FlapCount, FlapDetected, FlapLastDetected, and FlapFirstSeen
tags on successive scope-simple runs within flap_window_days
(default 7 days). Detection-only — does not change remediation
behavior. Visibility mechanism for conflicts with externally-managed
policies (Terraform/CFN/GitOps).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add tag-based exemption (read path)

**Files:**
- Modify: `variables.tf` (append 3 variables)
- Modify: `main.tf` (add 3 parameter blocks)
- Modify: `ssm/document.yaml` (extend parameters + CheckExclusion step + InputPayload)
- Modify: `tests/plan.tftest.hcl` (append assertion)

- [ ] **Step 1: Write the failing test**

Append to the `run "plan_resources"` block:

```hcl
  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "TagBasedExemptionEnabled"][0] == "true"
    error_message = "tag_based_exemption_enabled must default to true (per design decision)"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "ExemptionTagKey"][0] == "CrwdRemediatorExempt"
    error_message = "exemption_tag_key must default to CrwdRemediatorExempt"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "RequireExemptionReason"][0] == "true"
    error_message = "require_exemption_reason must default to true (fail-loud on bare boolean exemptions)"
  }
```

- [ ] **Step 2: Run tests; verify failure**

Run: `terraform test`
Expected: the three new assertions fail (parameters don't exist yet).

- [ ] **Step 3: Add the three variables to `variables.tf`**

Append:

```hcl
variable "tag_based_exemption_enabled" {
  type        = bool
  description = "If true, the SSM document's CheckExclusion step reads policy tags and skips remediation when CrwdRemediatorExempt=true is present with a valid reason. Defaults to true — intended workflow is for operators to pre-tag known break-glass/admin policies before terraform apply."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key used to exempt a policy from remediation. Value 'true' triggers skip logic. Kept as a variable so the namespace can be aligned with other CRWD tooling conventions."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "If true, the exemption tag is only honored when a companion CrwdRemediatorExemptReason tag contains a non-empty string. Bare boolean exemptions are ignored (and logged) when this is true, ensuring every exemption is auditable."
  default     = true
}
```

- [ ] **Step 4: Add the three parameter blocks in `main.tf`**

In `main.tf`, inside `resource "aws_config_remediation_configuration" "this"`, append three more `parameter` blocks after the `FlapWindowDays` block added in Task 3:

```hcl
  parameter {
    name         = "TagBasedExemptionEnabled"
    static_value = var.tag_based_exemption_enabled ? "true" : "false"
  }

  parameter {
    name         = "ExemptionTagKey"
    static_value = var.exemption_tag_key
  }

  parameter {
    name         = "RequireExemptionReason"
    static_value = var.require_exemption_reason ? "true" : "false"
  }
```

- [ ] **Step 5: Add the three parameters to `ssm/document.yaml`**

In `ssm/document.yaml`, inside the top-level `parameters:` block (after `FlapWindowDays` added in Task 3), insert:

```yaml
  TagBasedExemptionEnabled:
    type: String
    default: "true"
    description: "If 'true', CheckExclusion reads IAM policy tags and skips remediation when CrwdRemediatorExempt=true"
    allowedValues:
      - "true"
      - "false"
  ExemptionTagKey:
    type: String
    default: "CrwdRemediatorExempt"
    description: "Tag key checked by CheckExclusion"
  RequireExemptionReason:
    type: String
    default: "true"
    description: "If 'true', the exemption tag is only honored when a CrwdRemediatorExemptReason tag contains a non-empty string"
    allowedValues:
      - "true"
      - "false"
```

- [ ] **Step 6: Extend the CheckExclusion step with tag-reading logic**

In `ssm/document.yaml`, replace the entire `CheckExclusion` step's `Script:` block. The current script is:

```python
        def handler(events, context):
            resource_id = events["ResourceId"]
            excluded = events.get("ExcludedResourceIds") or []
            if resource_id in excluded:
                return {"action": "skip", "reason": f"{resource_id} is in the exclusion list"}
            return {"action": "remediate"}
```

Replace with:

```python
        import boto3
        import datetime

        def handler(events, context):
            resource_id = events["ResourceId"]
            excluded = events.get("ExcludedResourceIds") or []

            # Existing: list-based exclusion
            if resource_id in excluded:
                return {"action": "skip", "reason": f"{resource_id} is in the exclusion list"}

            # New: tag-based exclusion
            if events.get("TagBasedExemptionEnabled", "false").lower() != "true":
                return {"action": "remediate"}

            exemption_tag_key = events.get("ExemptionTagKey", "CrwdRemediatorExempt")
            require_reason = events.get("RequireExemptionReason", "true").lower() == "true"

            iam = boto3.client("iam")
            try:
                tags_resp = iam.list_policy_tags(PolicyArn=resource_id)
                tag_map = {t["Key"]: t["Value"] for t in tags_resp.get("Tags", [])}
            except Exception as e:
                print(f"WARN: tag lookup failed on {resource_id}: {e} - proceeding with remediation")
                return {"action": "remediate", "reason": f"tag lookup failed: {e}"}

            exempt_value = tag_map.get(exemption_tag_key, "").lower()
            if exempt_value != "true":
                return {"action": "remediate"}

            if require_reason:
                reason = tag_map.get("CrwdRemediatorExemptReason", "").strip()
                if not reason:
                    print(f"WARN: exemption tag on {resource_id} has no reason - ignoring exemption")
                    return {"action": "remediate", "reason": "exemption missing required reason tag"}

            expiry = tag_map.get("CrwdRemediatorExemptExpiry", "")
            if expiry:
                try:
                    expiry_dt = datetime.datetime.strptime(expiry, "%Y-%m-%d")
                    if datetime.datetime.utcnow() > expiry_dt:
                        return {"action": "remediate", "reason": f"exemption expired on {expiry}"}
                except ValueError:
                    # Invalid expiry format on a human-applied exemption - fail open (treat as no expiry)
                    pass

            reason = tag_map.get("CrwdRemediatorExemptReason", "exempt via tag")
            return {"action": "skip", "reason": reason}
```

- [ ] **Step 7: Update the CheckExclusion InputPayload**

In `ssm/document.yaml`, locate the `CheckExclusion` step's `InputPayload:` (around line 49-51). The current block is:

```yaml
      InputPayload:
        ResourceId: "{{ ResourceId }}"
        ExcludedResourceIds: "{{ ExcludedResourceIds }}"
```

Change to:

```yaml
      InputPayload:
        ResourceId: "{{ ResourceId }}"
        ExcludedResourceIds: "{{ ExcludedResourceIds }}"
        TagBasedExemptionEnabled: "{{ TagBasedExemptionEnabled }}"
        ExemptionTagKey: "{{ ExemptionTagKey }}"
        RequireExemptionReason: "{{ RequireExemptionReason }}"
```

- [ ] **Step 8: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/ssm/document.yaml'))"`
Expected: no output (clean parse).

- [ ] **Step 9: Run tests; verify all pass**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`
Expected: all assertions pass.

- [ ] **Step 10: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/variables.tf \
        modules/iam-wildcard-action-policy/main.tf \
        modules/iam-wildcard-action-policy/ssm/document.yaml \
        modules/iam-wildcard-action-policy/tests/plan.tftest.hcl
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): add tag-based exemption read path

CheckExclusion now reads IAM policy tags and honors
CrwdRemediatorExempt=true when paired with a non-empty
CrwdRemediatorExemptReason. CrwdRemediatorExemptExpiry is respected
when present (auto-exempt will set it in a follow-up).

Defaults: tag_based_exemption_enabled=true, require_exemption_reason=true.
Fails-open (proceeds with remediation) on IAM API errors or missing
reason to avoid silent wildcard creep.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add auto-exempt on flap (write path)

**Files:**
- Modify: `variables.tf` (append 3 variables)
- Modify: `main.tf` (3 more parameter blocks + precondition)
- Modify: `ssm/document.yaml` (add 3 more parameters + scope-simple auto-exempt write logic + InputPayload)
- Modify: `tests/plan.tftest.hcl` (append assertions)

- [ ] **Step 1: Write the failing test**

Append to the `run "plan_resources"` block:

```hcl
  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "AutoExemptEnabled"][0] == "false"
    error_message = "auto_exempt_on_flap_enabled must default to false (opt-in)"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "AutoExemptFlapThreshold"][0] == "3"
    error_message = "auto_exempt_flap_threshold must default to 3"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "AutoExemptDurationDays"][0] == "30"
    error_message = "auto_exempt_duration_days must default to 30"
  }
```

And add a new run block to verify the cross-variable precondition:

```hcl
run "auto_exempt_requires_tag_based_exemption" {
  command = plan

  variables {
    name_prefix                 = "test"
    tag_based_exemption_enabled = false
    auto_exempt_on_flap_enabled = true
  }

  expect_failures = [
    terraform_data.validation,
  ]
}
```

- [ ] **Step 2: Run tests; verify failure**

Run: `terraform test`
Expected: the four new assertions/expectations fail.

- [ ] **Step 3: Add the three variables to `variables.tf`**

Append:

```hcl
variable "auto_exempt_on_flap_enabled" {
  type        = bool
  description = "If true, the SSM document self-applies CrwdRemediatorExempt=true on policies whose FlapCount reaches auto_exempt_flap_threshold. Requires tag_based_exemption_enabled=true. Opt-in — default false — because it silently pauses enforcement on the affected policy until the expiry."
  default     = false
}

variable "auto_exempt_flap_threshold" {
  type        = number
  description = "Number of flap cycles that triggers auto-exemption. Only applies when auto_exempt_on_flap_enabled = true."
  default     = 3
  validation {
    condition     = var.auto_exempt_flap_threshold >= 2 && var.auto_exempt_flap_threshold <= 20
    error_message = "auto_exempt_flap_threshold must be between 2 and 20."
  }
}

variable "auto_exempt_duration_days" {
  type        = number
  description = "Days until an auto-applied exemption expires. After expiry, the exemption tag is ignored and remediation resumes. Set low to force quick human review."
  default     = 30
  validation {
    condition     = var.auto_exempt_duration_days >= 1 && var.auto_exempt_duration_days <= 365
    error_message = "auto_exempt_duration_days must be between 1 and 365."
  }
}
```

- [ ] **Step 4: Add the precondition resource to `main.tf`**

Append to the very top of `main.tf`, right after the existing `locals { }` block:

```hcl
resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = !var.auto_exempt_on_flap_enabled || var.tag_based_exemption_enabled
      error_message = "auto_exempt_on_flap_enabled = true requires tag_based_exemption_enabled = true. Tag-based exemption must be on for auto-exempt to have any effect."
    }
  }
}
```

- [ ] **Step 5: Add three parameter blocks in `main.tf`**

Inside `aws_config_remediation_configuration.this`, after the `RequireExemptionReason` parameter added in Task 4, append:

```hcl
  parameter {
    name         = "AutoExemptEnabled"
    static_value = var.auto_exempt_on_flap_enabled ? "true" : "false"
  }

  parameter {
    name         = "AutoExemptFlapThreshold"
    static_value = tostring(var.auto_exempt_flap_threshold)
  }

  parameter {
    name         = "AutoExemptDurationDays"
    static_value = tostring(var.auto_exempt_duration_days)
  }
```

- [ ] **Step 6: Add three parameters to `ssm/document.yaml`**

In the top-level `parameters:` block (after `RequireExemptionReason` from Task 4):

```yaml
  AutoExemptEnabled:
    type: String
    default: "false"
    description: "If 'true', auto-apply exemption tag when FlapCount reaches AutoExemptFlapThreshold"
    allowedValues:
      - "true"
      - "false"
  AutoExemptFlapThreshold:
    type: String
    default: "3"
    description: "Flap count that triggers auto-exemption (only applies when AutoExemptEnabled=true)"
  AutoExemptDurationDays:
    type: String
    default: "30"
    description: "Days until auto-applied exemption expires"
```

- [ ] **Step 7: Add auto-exempt write logic in the scope-simple branch**

In `ssm/document.yaml`, in the scope-simple branch, immediately AFTER the `iam.tag_policy(...)` call that now includes `flap_tags` (added in Task 3), add:

```python
                # Auto-exempt on flap threshold
                auto_exempt_enabled = events.get("AutoExemptEnabled", "false").lower() == "true"
                auto_exempt_threshold = int(events.get("AutoExemptFlapThreshold", "3"))
                auto_exempt_duration_days = int(events.get("AutoExemptDurationDays", "30"))

                if auto_exempt_enabled and flap_count >= auto_exempt_threshold:
                    expiry_date = (datetime.datetime.utcnow() + datetime.timedelta(days=auto_exempt_duration_days)).strftime("%Y-%m-%d")
                    iam.tag_policy(
                        PolicyArn=policy_arn,
                        Tags=[
                            {"Key": "CrwdRemediatorExempt", "Value": "true"},
                            {"Key": "CrwdRemediatorExemptReason", "Value": f"auto-applied after {flap_count} flap cycles within {flap_window_days}d window"},
                            {"Key": "CrwdRemediatorExemptExpiry", "Value": expiry_date},
                            {"Key": "CrwdAutoExempted", "Value": "true"},
                        ],
                    )
                    result["AutoExempted"] = "true"
                    result["AutoExemptExpiry"] = expiry_date
```

- [ ] **Step 8: Update the scope-simple handler's InputPayload**

In `ssm/document.yaml`, locate the `ReadPolicyAndAnalyze` step's `InputPayload:` (updated in Task 3 to include `FlapWindowDays`). Add the three new parameters:

```yaml
      InputPayload:
        ResourceId: "{{ ResourceId }}"
        Action: "{{ Action }}"
        CloudTrailLookbackDays: "{{ CloudTrailLookbackDays }}"
        MinActionsThreshold: "{{ MinActionsThreshold }}"
        ReportS3Bucket: "{{ ReportS3Bucket }}"
        FlapWindowDays: "{{ FlapWindowDays }}"
        AutoExemptEnabled: "{{ AutoExemptEnabled }}"
        AutoExemptFlapThreshold: "{{ AutoExemptFlapThreshold }}"
        AutoExemptDurationDays: "{{ AutoExemptDurationDays }}"
```

- [ ] **Step 9: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/ssm/document.yaml'))"`
Expected: no output.

- [ ] **Step 10: Run tests; verify all pass**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`
Expected: all assertions pass including the new `auto_exempt_requires_tag_based_exemption` precondition test.

- [ ] **Step 11: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/variables.tf \
        modules/iam-wildcard-action-policy/main.tf \
        modules/iam-wildcard-action-policy/ssm/document.yaml \
        modules/iam-wildcard-action-policy/tests/plan.tftest.hcl
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): add auto-exempt on flap

When auto_exempt_on_flap_enabled=true and FlapCount reaches
auto_exempt_flap_threshold, the SSM document self-applies
CrwdRemediatorExempt=true with a time-bounded
CrwdRemediatorExemptExpiry tag (default 30 days). Auto-exemptions are
marked CrwdAutoExempted=true to distinguish them from human-applied
exemptions in audits.

Opt-in — default false. Cross-variable precondition ensures
auto_exempt_on_flap_enabled=true requires
tag_based_exemption_enabled=true.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update README (operator patterns + inputs + quick-start)

**Files:**
- Modify: `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/README.md`

- [ ] **Step 1: Update the quick-start section to lead with tagging**

In `README.md`, find the "Quick start (deployment guide)" section (around line 48). Before the current step 1 (`cp -r modules/iam-wildcard-action-policy/examples/basic ...`), insert a new step 0:

```markdown
0. **Tag any break-glass or core-system policies that should be exempt from remediation.** Before `terraform apply`, apply these tags to each IAM policy you want the module to skip:

   ```bash
   aws iam tag-policy \
     --policy-arn arn:aws:iam::123456789012:policy/BreakGlassAdminPolicy \
     --tags Key=CrwdRemediatorExempt,Value=true \
            Key=CrwdRemediatorExemptReason,Value="Break-glass role for SRE incident response"
   ```

   The reason tag is required by default (see `require_exemption_reason`). Exemption tags without a non-empty reason are ignored. This is intentional: every exemption should be auditable.
```

- [ ] **Step 2: Insert the "When policies are externally managed" section**

After the existing "Per-resource exclusion (Tier 1)" section (ends around line 156) and BEFORE the "Rollback procedure" section, insert:

```markdown
## When policies are externally managed

If an IAM policy is managed by Terraform, CloudFormation, or any other declarative source of truth, and its source definition contains a wildcard action, this module's auto-remediation will fight the source:

```
git push (policy.tf has ssm:*)
  → terraform apply writes wildcard version
    → Config detects NON_COMPLIANT → SSM scopes → wildcard replaced
      → next terraform apply detects drift, re-writes wildcard
        → Config detects → SSM scopes again → flap
```

This is called the **flap loop**. The module detects and tags it (see "Flap-detection tags" below) but does not stop it — the remediation keeps doing its job. You have three options:

| Pattern | When to use | How |
|---------|-------------|-----|
| **Fix at source** | The owning team can update the source-of-truth | Run `Action=suggest-moderate` or `Action=analyze` to discover the action list, then update the Terraform/CFN to use specific actions instead of the wildcard. Submit a PR at source. |
| **Exclude, then fix at source on a schedule** | The fix requires change-window coordination | Either (a) tag the policy `CrwdRemediatorExempt=true` with a `CrwdRemediatorExemptReason` like `"awaiting Q2 IAM cleanup; owner=team-x"`, or (b) add the ARN to the module's `excluded_resource_ids` list. Resume remediation by removing the tag/entry after the source fix lands. |
| **Accept the flap** | Policy is test-only, short-lived, or the flap is a forcing function to push the owning team to act | Do nothing. The `FlapDetected=true` tag plus daily CloudTrail noise surfaces the problem to whoever owns the policy. |

### Find flapping policies

```bash
aws iam list-policies --scope Local --query "Policies[].Arn" --output text | while read arn; do
  flap=$(aws iam list-policy-tags --policy-arn "$arn" \
    --query "Tags[?Key=='FlapDetected'].Value" --output text 2>/dev/null)
  [ "$flap" = "true" ] && echo "$arn"
done
```

### Flap-detection tags

The SSM document writes these tags whenever `scope-simple` runs on the same policy twice within `flap_window_days` (default 7):

| Tag | Value | Meaning |
|-----|-------|---------|
| `FlapCount` | integer string | Number of successive scopes within the flap window |
| `FlapDetected` | `"true"` | Set on second scope within the window; persists as audit history |
| `FlapFirstSeen` | ISO-8601 timestamp | When the first flap in the current episode was observed |
| `FlapLastDetected` | ISO-8601 timestamp | When the most recent flap was observed |

These tags are informational only — they do not change remediation behavior.

### Exemption tag schema

| Tag | Value | Who writes it | Required? |
|-----|-------|--------------|-----------|
| `CrwdRemediatorExempt` | `"true"` | Human operator OR module (auto-exempt) | Yes — gate |
| `CrwdRemediatorExemptReason` | Non-empty string describing the justification | Human operator OR module (auto-exempt) | Yes when `require_exemption_reason = true` (default) |
| `CrwdRemediatorExemptExpiry` | ISO-8601 date (`YYYY-MM-DD`) | Module only (auto-exempt writes this; human-applied exemptions typically omit it) | No — when absent, human-applied exemptions never expire |
| `CrwdAutoExempted` | `"true"` | Module only | Marks auto-applied exemptions; used by CrowdStrike filters to distinguish from human-applied |

Human-applied exemptions have no expiry by default. Auto-applied exemptions expire after `auto_exempt_duration_days` (default 30) and the module resumes remediation.
```

- [ ] **Step 3: Update the Inputs reference table**

In `README.md`, find the "Inputs reference" section (around line 100). Replace the existing table with the expanded version that includes the new variables:

```markdown
| Input | Type | Default | What to put here |
|-------|------|---------|-----------------|
| `name_prefix` | string | (required) | A short project/team identifier (e.g., `prod-security`). Becomes part of all resource names. |
| `tags` | map(string) | `{}` | Your standard resource tags (e.g., `{ Environment = "prod", Team = "security" }`). |
| `automatic_remediation` | bool | `false` | Leave `false` until you've reviewed the non-compliance list. Only set `true` after confirming the analyze results look correct. |
| `remediation_action` | string | `"analyze"` | Which SSM mode Config invokes automatically. `analyze` = tag-only (safe default), `scope-simple` = auto-rewrite Simple policies, `suggest-moderate` = generate suggestions. |
| `evaluation_frequency` | string | `"TwentyFour_Hours"` | How often Config re-evaluates all in-scope policies. `Off` disables the schedule (change-only evaluation). Options: `Off`, `One_Hour`, `Three_Hours`, `Six_Hours`, `Twelve_Hours`, `TwentyFour_Hours`. |
| `excluded_resource_ids` | list(string) | `[]` | IAM policy ARNs that should never be remediated. Use for admin policies, break-glass roles, or other legitimate wildcard users. Centrally-managed via Terraform. |
| `tag_based_exemption_enabled` | bool | `true` | Read policy tags for exemption. Default on — the intended workflow is to pre-tag break-glass policies with `CrwdRemediatorExempt=true` before `terraform apply`. |
| `exemption_tag_key` | string | `"CrwdRemediatorExempt"` | Tag key to check for exemption. Change only if aligning with existing CRWD tooling. |
| `require_exemption_reason` | bool | `true` | Require a non-empty `CrwdRemediatorExemptReason` tag alongside the boolean. Prevents silent bypass via bare tag application. |
| `auto_exempt_on_flap_enabled` | bool | `false` | Opt-in. When true, the module self-applies exemption tags on policies that flap `auto_exempt_flap_threshold` times. Pauses enforcement for `auto_exempt_duration_days`, then resumes. |
| `auto_exempt_flap_threshold` | number | `3` | Flap count that triggers auto-exempt (only when `auto_exempt_on_flap_enabled = true`). |
| `auto_exempt_duration_days` | number | `30` | How long auto-applied exemptions last before expiring. Shorter = more human-review pressure. |
| `flap_window_days` | number | `7` | Days within which successive scopes on the same policy count as a flap. Used only for the `FlapDetected` tag. |
| `cloudtrail_lookback_days` | number | `90` | How many days of CloudTrail history to scan in scope-simple/suggest-moderate modes. More days = better coverage. |
| `min_actions_threshold` | number | `3` | Minimum distinct actions found in CloudTrail before auto-scoping proceeds. Below this, the policy is tagged NeedsManualReview. |
| `report_s3_bucket` | string | `""` | S3 bucket name for JSON analysis reports. Leave empty to use policy tags only. |
```

- [ ] **Step 4: Add a terraform-fmt check equivalent for markdown**

Markdown doesn't have `fmt -check`. Just verify the file renders cleanly:

Run: `head -80 /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/README.md`
Expected: readable output with no broken markdown.

- [ ] **Step 5: Commit**

```bash
cd /home/mlopez/crwd-remediators
git add modules/iam-wildcard-action-policy/README.md
git commit -m "$(cat <<'EOF'
docs(iam-wildcard-action-policy): document v1.1.0 features

Adds "When policies are externally managed" section covering the
three operator patterns (fix at source / exclude / accept).
Documents flap-detection tag schema and exemption tag schema.
Updates quick-start to lead with pre-apply tagging of break-glass
policies. Expands Inputs reference table with the nine new
variables.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update examples/basic pass-throughs

**Files:**
- Modify: `examples/basic/main.tf`
- Modify: `examples/basic/variables.tf`
- Modify: `examples/basic/terraform.tfvars.example`

- [ ] **Step 1: Add pass-through in `examples/basic/main.tf`**

Extend the existing `module "iam_wildcard_action_policy"` block (currently at lines 5-15) to pass through the new variables:

```hcl
provider "aws" {
  region = "us-east-1"
}

module "iam_wildcard_action_policy" {
  source = "../../"

  name_prefix                 = var.name_prefix
  tags                        = var.tags
  automatic_remediation       = var.automatic_remediation
  remediation_action          = var.remediation_action
  evaluation_frequency        = var.evaluation_frequency
  excluded_resource_ids       = var.excluded_resource_ids
  cloudtrail_lookback_days    = var.cloudtrail_lookback_days
  min_actions_threshold       = var.min_actions_threshold
  report_s3_bucket            = var.report_s3_bucket
  flap_window_days            = var.flap_window_days
  tag_based_exemption_enabled = var.tag_based_exemption_enabled
  exemption_tag_key           = var.exemption_tag_key
  require_exemption_reason    = var.require_exemption_reason
  auto_exempt_on_flap_enabled = var.auto_exempt_on_flap_enabled
  auto_exempt_flap_threshold  = var.auto_exempt_flap_threshold
  auto_exempt_duration_days   = var.auto_exempt_duration_days
}

output "config_rule_name" {
  value = module.iam_wildcard_action_policy.config_rule_name
}

output "ssm_document_name" {
  value = module.iam_wildcard_action_policy.ssm_document_name
}

output "iam_role_arn" {
  value = module.iam_wildcard_action_policy.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  value = module.iam_wildcard_action_policy.non_compliant_resources_cli_command
}
```

- [ ] **Step 2: Add variable declarations in `examples/basic/variables.tf`**

Append:

```hcl
variable "remediation_action" {
  type        = string
  description = "SSM action Config invokes automatically."
  default     = "analyze"
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all IAM policies."
  default     = "TwentyFour_Hours"
}

variable "flap_window_days" {
  type        = number
  description = "Days within which successive scopes count as a flap."
  default     = 7
}

variable "tag_based_exemption_enabled" {
  type        = bool
  description = "Honor CrwdRemediatorExempt tag on policies."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key checked for exemption."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "Require a companion reason tag for exemption to be honored."
  default     = true
}

variable "auto_exempt_on_flap_enabled" {
  type        = bool
  description = "Auto-apply exemption tag on flap-threshold policies."
  default     = false
}

variable "auto_exempt_flap_threshold" {
  type        = number
  description = "Flap count that triggers auto-exempt."
  default     = 3
}

variable "auto_exempt_duration_days" {
  type        = number
  description = "Days until auto-applied exemption expires."
  default     = 30
}
```

- [ ] **Step 3: Add commented entries in `examples/basic/terraform.tfvars.example`**

Append after the existing block:

```
# --- v1.1.0 additions ---

# Which SSM mode Config invokes automatically. "analyze" = tag-only (safe).
# "scope-simple" auto-rewrites single-wildcard policies. "suggest-moderate"
# generates suggestions for multi-wildcard policies.
# remediation_action = "analyze"

# How often Config re-evaluates all in-scope IAM policies. Use "Off" to
# disable the schedule entirely (change-triggered only, matching v1.0.0).
# Options: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours
# evaluation_frequency = "TwentyFour_Hours"

# Days within which successive scopes on the same policy are considered a flap.
# Only affects FlapDetected/FlapCount tagging.
# flap_window_days = 7

# Honor the CrwdRemediatorExempt=true tag on policies (default on).
# Set to false to only allow exclusions via excluded_resource_ids.
# tag_based_exemption_enabled = true

# Tag key to check for exemption. Change only to align with existing tooling.
# exemption_tag_key = "CrwdRemediatorExempt"

# Require a non-empty CrwdRemediatorExemptReason alongside the boolean.
# Strongly recommended: keep this true.
# require_exemption_reason = true

# Auto-apply exemption tag on policies that flap repeatedly.
# Off by default because it silently pauses enforcement. CrowdStrike
# monitors the CrwdAutoExempted=true tag if you turn this on.
# auto_exempt_on_flap_enabled = false

# Flap count that triggers auto-exempt (only when auto_exempt_on_flap_enabled=true).
# auto_exempt_flap_threshold = 3

# Days until the auto-applied exemption expires and remediation resumes.
# Shorter = more human-review pressure.
# auto_exempt_duration_days = 30
```

- [ ] **Step 4: Verify the example still plans cleanly**

Run:
```bash
cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/examples/basic
terraform init -upgrade
terraform plan -no-color | tail -5
```

Expected: `Plan: 9 to add, 0 to change, 0 to destroy.` (same count as v1.0.0 — no new resources, only new parameters on the existing remediation config).

- [ ] **Step 5: Format and commit**

```bash
cd /home/mlopez/crwd-remediators
terraform fmt -recursive modules/iam-wildcard-action-policy
git add modules/iam-wildcard-action-policy/examples/basic/main.tf \
        modules/iam-wildcard-action-policy/examples/basic/variables.tf \
        modules/iam-wildcard-action-policy/examples/basic/terraform.tfvars.example
git commit -m "$(cat <<'EOF'
feat(iam-wildcard-action-policy): wire v1.1.0 variables through basic example

Pass-through for the nine new variables so operators can deploy the
full v1.1.0 feature surface from examples/basic.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: CHANGELOG entry

**Files:**
- Modify: `/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/CHANGELOG.md`

- [ ] **Step 1: Prepend the v1.1.0 entry**

Open `CHANGELOG.md`. Insert the new entry BEFORE the existing `## [1.0.0]` heading (so it appears at the top of the version list, right after the preamble):

```markdown
## [1.1.0] — 2026-04-15

### Added
- `remediation_action` variable — wires the SSM document's `Action` parameter through Terraform, letting operators configure Config to auto-invoke `scope-simple` or `suggest-moderate` instead of hardcoded `analyze`.
- `evaluation_frequency` variable — adds a `ScheduledNotification` source_detail to the Config rule so it periodically re-evaluates all in-scope IAM policies (covers existing resources and ongoing drift). Default `TwentyFour_Hours`; `Off` disables the schedule.
- Flap-detection tags (`FlapCount`, `FlapDetected`, `FlapFirstSeen`, `FlapLastDetected`) emitted by `scope-simple` when the same policy is scoped twice within `flap_window_days` (default 7). Detection-only — does not change remediation behavior.
- Tag-based exemption mechanism — `CheckExclusion` reads `CrwdRemediatorExempt=true` tag on policies and skips remediation when paired with a non-empty `CrwdRemediatorExemptReason`. Respects `CrwdRemediatorExemptExpiry` dates. Variables: `tag_based_exemption_enabled` (default `true`), `exemption_tag_key`, `require_exemption_reason` (default `true`).
- Auto-exempt on flap threshold — opt-in behavior where the SSM document self-applies `CrwdRemediatorExempt=true` on policies whose `FlapCount` reaches `auto_exempt_flap_threshold`. Auto-exemptions carry a `CrwdRemediatorExemptExpiry` date (default 30 days out) and a `CrwdAutoExempted=true` marker for audit distinction. Off by default (`auto_exempt_on_flap_enabled = false`).
- README section "When policies are externally managed" documenting the three operator patterns (fix at source / exclude / accept) for resolving flap loops with Terraform/CFN/GitOps-managed policies.

### Changed
- Config rule now has a third `source_detail` block (`ScheduledNotification`) by default. Opt out by setting `evaluation_frequency = "Off"`.
- `CheckExclusion` step in the SSM document now reads IAM policy tags (`iam:ListPolicyTags`) in addition to the existing `excluded_resource_ids` list check. Existing SSM role already had this permission; no IAM changes required.
- Quick-start deployment guide now leads with pre-apply tagging of break-glass policies to match the new default-on tag-based-exemption workflow.
```

- [ ] **Step 2: Commit**

```bash
cd /home/mlopez/crwd-remediators
git add modules/iam-wildcard-action-policy/CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(iam-wildcard-action-policy): add v1.1.0 CHANGELOG entry

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final verification

This task does NOT produce a commit — it runs the review gates and reports. Any issues found here feed back into the prior tasks (amend or add a follow-up fix commit).

**Files:** none modified.

- [ ] **Step 1: Verify terraform fmt is clean**

Run: `cd /home/mlopez/crwd-remediators && terraform fmt -check -recursive modules/iam-wildcard-action-policy`
Expected: exit code 0, no output.

If files are reported: run `terraform fmt -recursive modules/iam-wildcard-action-policy` and make a follow-up commit labeled `style(iam-wildcard-action-policy): terraform fmt`.

- [ ] **Step 2: Run terraform test**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy && terraform test`
Expected: all run blocks pass. Count should be the original 1 run (`plan_resources`) plus the new runs added in Tasks 1, 2, 5. Total assertions ≥15.

- [ ] **Step 3: Run example plan end-to-end**

Run:
```bash
cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/examples/basic
terraform init -upgrade 2>&1 | tail -5
terraform plan -no-color 2>&1 | tail -10
```
Expected: `Plan: 9 to add, 0 to change, 0 to destroy.`

- [ ] **Step 4: Validate SSM YAML**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('/home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/ssm/document.yaml')); print('parameters:', len(d['parameters'])); print('mainSteps:', len(d['mainSteps']))"`
Expected: `parameters: 11` (original 7 + 4 new: FlapWindowDays, TagBasedExemptionEnabled, ExemptionTagKey, RequireExemptionReason; wait — plus AutoExemptEnabled, AutoExemptFlapThreshold, AutoExemptDurationDays = 7 new = 14 total. Let me recount: original parameters are ResourceId, ExcludedResourceIds, AutomationAssumeRole, Action, CloudTrailLookbackDays, MinActionsThreshold, ReportS3Bucket = 7. New: FlapWindowDays, TagBasedExemptionEnabled, ExemptionTagKey, RequireExemptionReason, AutoExemptEnabled, AutoExemptFlapThreshold, AutoExemptDurationDays = 7. Total = 14. So expect `parameters: 14`.) `mainSteps: 4` (unchanged: CheckExclusion, BranchOnExclusion, ReadPolicyAndAnalyze, ExitSkipped).

- [ ] **Step 5: Invoke the reviewing-a-remediator skill**

From the repo root, ask the reviewing skill to audit the module:

```
review iam-wildcard-action-policy
```

Expected: `VERDICT: READY TO TAG` with 0 BLOCKERS and 0 WARNINGS (suggestions are acceptable). The skill will run all 18 gates and produce a report.

If BLOCKERs are reported: circle back to the appropriate task and fix. Do not proceed to tagging until verdict is clean.

- [ ] **Step 6: Verify git log is clean**

Run: `cd /home/mlopez/crwd-remediators && git log --oneline -10`
Expected: a clean sequence of feat/docs commits for Tasks 1-8, all with Co-Authored-By trailers. No `fixup!` or `wip` commits.

- [ ] **Step 7: Surface any outstanding design-spec "Open questions" that need user sign-off before tag**

Re-read the spec's Open Questions section. Four items:
1. FlapDetected persistence — the implementation above persists per my lean.
2. CrwdAutoExempted persistence — the implementation above persists per my lean.
3. Precondition location — implemented as Terraform precondition per my lean.
4. CHANGELOG date — used 2026-04-15 (design date); confirm this matches the intended tag date.

If the user wants any of these changed, circle back to the appropriate task.

- [ ] **Step 8: Report readiness to the user**

Print a concise summary:

```
Implementation of iam-wildcard-action-policy v1.1.0 complete.

Commits: <N> on main
Tests: <count> plan-mode assertions passing
Review verdict: READY TO TAG

Next step (NOT part of this plan): tag the module.
  git tag iam-wildcard-action-policy/v1.1.0
  git push --tags
```

The tagging step is intentionally out of scope for this plan — it's a release action that should be confirmed interactively with the user.

---

## Spec coverage cross-check

Walking the spec's "Component design" section against this plan's tasks:

| Spec component | Implemented in task(s) |
|---|---|
| 1. `remediation_action` variable | Task 1 |
| 2. `evaluation_frequency` variable (scheduled sweep) | Task 2 |
| 3. README operator-patterns section | Task 6 |
| 4. Flap-detection tags | Task 3 (flap_window_days var + SSM logic) |
| 5a. Tag-based exemption (read path) | Task 4 |
| 5b. Auto-exempt on flap (write path) | Task 5 |
| Parameter wiring (SSM ⇄ remediation config) | Tasks 3, 4, 5 (each adds its own parameters) |
| Safety analysis invariants | Preserved by implementation (each task's code changes do not touch `min_actions_threshold`, `category != Simple` checks, or `lambda/handler.py`) |
| Testing plan (plan-mode) | Tasks 1-5 each add assertions; Task 9 runs the full suite |
| Testing plan (apply-mode, optional) | NOT implemented — marked optional in spec; operators can add `tests/apply.tftest.hcl` later |
| File change summary | Tasks 1-8 collectively touch the files in the spec's table |
| Rollout plan (two deltas documented in CHANGELOG) | Task 8 |
| Version bump 1.0.0 → 1.1.0 | Task 8 (CHANGELOG) + Task 9 (tagging guidance) |
| Open questions sign-off | Task 9, Step 7 |

Every spec requirement has a corresponding task.
