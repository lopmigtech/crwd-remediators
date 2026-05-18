# `iam-wildcard-action-policy-dashboard` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a sibling Terraform module `modules/iam-wildcard-action-policy-dashboard/` that hosts a self-refreshing read-only HTML dashboard for the `iam-wildcard-action-policy` remediator, behind an IAM-authed Lambda Function URL that 302-redirects to a presigned S3 URL.

**Architecture:** Two-Lambda split. A scheduled "refresh" Lambda calls Config + IAM (read-only) and writes rendered HTML to a private S3 bucket. A "redirect" Lambda fronted by an `aws_lambda_function_url` with `AWS_IAM` auth generates a short-TTL presigned URL on demand and returns HTTP 302. Bucket has Block Public Access, SSE-S3, versioning, TLS-only bucket policy, and optional server-access logging.

**Tech Stack:** Terraform (>= 1.6.0), AWS provider (~> 5.0), Python 3.12 (Lambda runtime), boto3 (provided by Lambda runtime — no vendoring), `archive_file` data source for Lambda packaging, `tftest.hcl` for plan-mode tests, Python `unittest.mock` for handler unit tests.

**Spec:** `docs/superpowers/specs/2026-04-27-iam-wildcard-dashboard-design.md`

---

## File Structure

**New module** at `modules/iam-wildcard-action-policy-dashboard/`:

```
modules/iam-wildcard-action-policy-dashboard/
├── CHANGELOG.md            # Module changelog (Keep a Changelog format)
├── README.md               # Module README; documents inputs, outputs, usage, security posture
├── data.tf                 # data sources: aws_partition, aws_caller_identity, aws_region
├── main.tf                 # All resources (S3 bucket, Lambdas, Function URL, EventBridge, log groups, IAM)
├── outputs.tf              # dashboard_url, bucket_name, refresh_lambda_function_name, redirect_lambda_function_name
├── variables.tf            # 8 variables with validations
├── versions.tf             # terraform >= 1.6.0, AWS provider ~> 5.0
├── examples/basic/
│   ├── main.tf             # Provider + module call
│   ├── variables.tf        # Pass-through vars
│   ├── outputs.tf          # Pass-through outputs
│   └── README.md           # Example usage walkthrough
├── lambda/
│   ├── refresh/
│   │   ├── dashboard.py    # Copy of operator-CLI script (~750 lines, copied verbatim from sibling module)
│   │   ├── handler.py      # ~40-line Lambda entrypoint wrapping dashboard helpers
│   │   └── test_handler.py # unittest.mock-based unit test
│   └── redirect/
│       ├── handler.py      # ~15-line Lambda entrypoint generating presigned URL + 302
│       └── test_handler.py # unittest.mock-based unit test
└── tests/
    └── plan.tftest.hcl     # 10 plan-mode assertions (Rule 9 requires ≥5)
```

**Modified files** (during live validation phase):
- `deployments/iam-test/main.tf` — add `module "iam_wildcard_dashboard"` block to validate end-to-end against existing test infra.

---

## Phase 0: Branch setup

### Task 1: Create feature branch

**Files:** none

- [ ] **Step 1: Verify clean working tree on main**

Run: `git -C /home/mlopez/crwd-remediators status -sb`
Expected: `## main...origin/main` and only the `?? deployments/iam-test/tfplan.live` untracked file (preserved from earlier session).

- [ ] **Step 2: Create and switch to feature branch**

Run: `git -C /home/mlopez/crwd-remediators checkout -b feat/iam-wildcard-dashboard-deploy`
Expected: `Switched to a new branch 'feat/iam-wildcard-dashboard-deploy'`

---

## Phase 1: Module skeleton

### Task 2: Scaffold the module directory + versions + data sources

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/versions.tf`
- Create: `modules/iam-wildcard-action-policy-dashboard/data.tf`
- Create: `modules/iam-wildcard-action-policy-dashboard/main.tf` (empty for now)
- Create: `modules/iam-wildcard-action-policy-dashboard/variables.tf` (empty for now)
- Create: `modules/iam-wildcard-action-policy-dashboard/outputs.tf` (empty for now)

- [ ] **Step 1: Create the module directory**

Run: `mkdir -p /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/{lambda/refresh,lambda/redirect,tests,examples/basic}`
Expected: directories created, no output.

- [ ] **Step 2: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
```

- [ ] **Step 3: Write `data.tf`**

```hcl
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

- [ ] **Step 4: Write empty stubs for `main.tf`, `variables.tf`, `outputs.tf`**

`main.tf`:
```hcl
# Resources defined in subsequent tasks.
```

`variables.tf`:
```hcl
# Variables defined in Task 3.
```

`outputs.tf`:
```hcl
# Outputs defined in Task 19.
```

- [ ] **Step 5: Run terraform init to verify scaffold validates**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform init -input=false 2>&1 | tail -5`
Expected: `Terraform has been successfully initialized!`

- [ ] **Step 6: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): scaffold module skeleton"
```

---

### Task 3: Add variables with validations

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/variables.tf`

- [ ] **Step 1: Write the full variables.tf**

```hcl
variable "name_prefix" {
  type        = string
  description = "Prefix used for naming the S3 bucket, Lambdas, IAM roles, and EventBridge rule."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources created by this module."
  default     = {}
}

# --- Module-specific inputs ---

variable "config_rule_name" {
  type        = string
  description = "Name of the AWS Config rule deployed by the iam-wildcard-action-policy module. Wire this from module.iam_wildcard_action_policy.config_rule_name."
}

variable "refresh_schedule_minutes" {
  type        = number
  description = "How often the refresh Lambda renders the dashboard. Lower values give fresher data; higher values reduce Config API call rate."
  default     = 15
  validation {
    condition     = var.refresh_schedule_minutes >= 5 && var.refresh_schedule_minutes <= 60
    error_message = "refresh_schedule_minutes must be between 5 and 60."
  }
}

variable "presigned_url_ttl_seconds" {
  type        = number
  description = "TTL of the presigned S3 URL the redirect Lambda generates. Stakeholders following the URL after expiry get an AWS-side 403."
  default     = 3600
  validation {
    condition     = var.presigned_url_ttl_seconds >= 60 && var.presigned_url_ttl_seconds <= 43200
    error_message = "presigned_url_ttl_seconds must be between 60 (1 minute) and 43200 (12 hours)."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days for both Lambdas. Must be one of AWS-supported values."
  default     = 30
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of: 1, 3, 5, 7, 14, 30, 60, 90, 180, 365, 400, 545, 731, 1827, 3653."
  }
}

variable "access_log_bucket" {
  type        = string
  description = "Optional S3 bucket name to receive server-access logs. If null, server-access logging is disabled and the consumer accepts the resulting s3-access-logging finding."
  default     = null
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "IAM policy IDs to filter out of the dashboard display. Honored by the refresh Lambda's collect step (Tier 2 exclusion per Rule 11)."
  default     = []
}
```

- [ ] **Step 2: Verify terraform validates**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform validate 2>&1`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/variables.tf
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): define module variables"
```

---

## Phase 2: S3 bucket with security mitigations (TDD per resource)

### Task 4: S3 bucket + first plan-mode test

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Write the failing test**

Create `tests/plan.tftest.hcl`:

```hcl
variables {
  name_prefix      = "test"
  config_rule_name = "test-iam-wildcard-action-policy"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = aws_s3_bucket.dashboard.bucket != ""
    error_message = "Module must create exactly one S3 bucket for the dashboard"
  }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `Reference to undeclared resource ... aws_s3_bucket.dashboard`.

- [ ] **Step 3: Write the bucket resource in main.tf**

Replace `main.tf` content with:

```hcl
locals {
  resource_prefix = "${var.name_prefix}-iam-wildcard-dashboard"
  bucket_name     = "${local.resource_prefix}-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------------
# S3 bucket — hosts the rendered dashboard.html. Private, encrypted, versioned.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "dashboard" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = var.tags
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): create dashboard S3 bucket"
```

---

### Task 5: Block Public Access + assertion

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Add the failing assertion to the existing run block**

Append inside `run "plan_resources" { ... }` (after the existing assert):

```hcl
  assert {
    condition = (
      aws_s3_bucket_public_access_block.dashboard.block_public_acls &&
      aws_s3_bucket_public_access_block.dashboard.block_public_policy &&
      aws_s3_bucket_public_access_block.dashboard.ignore_public_acls &&
      aws_s3_bucket_public_access_block.dashboard.restrict_public_buckets
    )
    error_message = "All four Block Public Access flags must be enabled on the dashboard bucket"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_s3_bucket_public_access_block.dashboard` undeclared.

- [ ] **Step 3: Add the BPA resource to main.tf**

Append to `main.tf`:

```hcl
resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): block all public access on bucket"
```

---

### Task 6: SSE encryption + assertion

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.dashboard.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "S3 bucket must have SSE-S3 (AES256) default encryption"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_s3_bucket_server_side_encryption_configuration.dashboard` undeclared.

- [ ] **Step 3: Add the encryption resource**

Append to `main.tf`:

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): enable SSE-S3 default encryption"
```

---

### Task 7: Versioning + assertion

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = aws_s3_bucket_versioning.dashboard.versioning_configuration[0].status == "Enabled"
    error_message = "S3 bucket versioning must be enabled"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_s3_bucket_versioning.dashboard` undeclared.

- [ ] **Step 3: Add the versioning resource**

Append to `main.tf`:

```hcl
resource "aws_s3_bucket_versioning" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): enable bucket versioning"
```

---

### Task 8: TLS-only bucket policy + assertion

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = length(regexall("aws:SecureTransport", aws_s3_bucket_policy.dashboard.policy)) > 0
    error_message = "Bucket policy must include a Deny statement on aws:SecureTransport=false"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_s3_bucket_policy.dashboard` undeclared.

- [ ] **Step 3: Add the bucket policy + supporting policy document**

Append to `main.tf`:

```hcl
data "aws_iam_policy_document" "dashboard_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.dashboard.arn,
      "${aws_s3_bucket.dashboard.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  policy = data.aws_iam_policy_document.dashboard_bucket.json
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): enforce TLS-only access via bucket policy"
```

---

### Task 9: Conditional server-access logging + assertion

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = length(aws_s3_bucket_logging.dashboard) == (var.access_log_bucket == null ? 0 : 1)
    error_message = "Server-access logging must be configured if access_log_bucket is set, and absent otherwise"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_s3_bucket_logging.dashboard` undeclared.

- [ ] **Step 3: Add the conditional logging resource**

Append to `main.tf`:

```hcl
resource "aws_s3_bucket_logging" "dashboard" {
  count = var.access_log_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.dashboard.id
  target_bucket = var.access_log_bucket
  target_prefix = "${local.resource_prefix}/"
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): conditional server-access logging"
```

---

## Phase 3: Lambda code + unit tests

### Task 10: Refresh Lambda handler with unit test

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/lambda/refresh/dashboard.py` (copy)
- Create: `modules/iam-wildcard-action-policy-dashboard/lambda/refresh/handler.py`
- Create: `modules/iam-wildcard-action-policy-dashboard/lambda/refresh/test_handler.py`

- [ ] **Step 1: Copy dashboard.py from the operator-CLI module**

Run: `cp /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy/dashboard/dashboard.py /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/refresh/dashboard.py`
Expected: file copied, no output.

Verify with: `wc -l /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/refresh/dashboard.py`
Expected: ~750 lines.

- [ ] **Step 2: Write the failing handler unit test**

Create `lambda/refresh/test_handler.py`:

```python
"""Unit tests for the refresh Lambda handler — uses mocked boto3 clients."""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))


class RefreshHandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ["CONFIG_RULE_NAME"] = "test-rule"
        os.environ["DASHBOARD_BUCKET"] = "test-bucket"
        os.environ["EXCLUDED_RESOURCE_IDS"] = ""

    def test_handler_renders_html_and_uploads_to_s3(self):
        import handler

        sts_client = MagicMock()
        sts_client.get_caller_identity.return_value = {"Account": "111111111111"}

        config_paginator = MagicMock()
        config_paginator.paginate.return_value = iter([{"EvaluationResults": []}])
        config_client = MagicMock()
        config_client.get_paginator.return_value = config_paginator

        iam_paginator = MagicMock()
        iam_paginator.paginate.return_value = iter([{"Policies": []}])
        iam_client = MagicMock()
        iam_client.get_paginator.return_value = iam_paginator

        s3_client = MagicMock()

        sess = MagicMock()
        sess.region_name = "us-east-1"
        sess.client.side_effect = lambda name, **kwargs: {
            "config": config_client, "iam": iam_client, "sts": sts_client, "s3": s3_client,
        }[name]

        with patch("handler.boto3.session.Session", return_value=sess):
            result = handler.lambda_handler({}, None)

        self.assertEqual(result["status"], "ok")
        s3_client.put_object.assert_called_once()
        kwargs = s3_client.put_object.call_args.kwargs
        self.assertEqual(kwargs["Bucket"], "test-bucket")
        self.assertEqual(kwargs["Key"], "dashboard.html")
        self.assertIn(b"<!DOCTYPE html>", kwargs["Body"])
        self.assertEqual(kwargs["ContentType"], "text/html; charset=utf-8")
        self.assertEqual(kwargs["ServerSideEncryption"], "AES256")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/refresh && /tmp/dash-venv/bin/python -m unittest test_handler.py -v 2>&1`
Expected: `ModuleNotFoundError: No module named 'handler'` or similar — handler.py doesn't exist yet.

- [ ] **Step 4: Write `handler.py`**

```python
"""Refresh Lambda handler. Renders the dashboard and uploads to S3."""

from __future__ import annotations

import os

import boto3

import dashboard


def lambda_handler(event, context):
    config_rule = os.environ["CONFIG_RULE_NAME"]
    bucket = os.environ["DASHBOARD_BUCKET"]
    excluded = {s for s in os.environ.get("EXCLUDED_RESOURCE_IDS", "").split(",") if s}

    sess = boto3.session.Session()
    cfg = sess.client("config")
    iam = sess.client("iam")
    sts = sess.client("sts")
    s3 = sess.client("s3")

    ident = sts.get_caller_identity()
    noncompliant = [
        n for n in dashboard.get_noncompliant_policies(cfg, config_rule)
        if n["resource_id"] not in excluded
    ]
    fleet = [
        p for p in dashboard.scan_fleet_tags(iam)
        if p["policy_id"] not in excluded
    ]

    state = dashboard.build_state(
        rule_name=config_rule,
        noncompliant=noncompliant,
        fleet=fleet,
        executions=None,
        account_id=ident.get("Account", "unknown"),
        region=sess.region_name or "unknown",
    )
    html = dashboard.render_html(state)

    s3.put_object(
        Bucket=bucket,
        Key="dashboard.html",
        Body=html.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
        ServerSideEncryption="AES256",
    )

    return {"status": "ok", "analyzed": state["totals"]["analyzed"]}
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/refresh && /tmp/dash-venv/bin/python -m unittest test_handler.py -v 2>&1`
Expected: `OK` and `Ran 1 test`.

- [ ] **Step 6: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/lambda/refresh/
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): add refresh Lambda handler with unit test"
```

---

### Task 11: Redirect Lambda handler with unit test

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/lambda/redirect/handler.py`
- Create: `modules/iam-wildcard-action-policy-dashboard/lambda/redirect/test_handler.py`

- [ ] **Step 1: Write the failing unit test**

Create `lambda/redirect/test_handler.py`:

```python
"""Unit tests for the redirect Lambda handler."""

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))


class RedirectHandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ["DASHBOARD_BUCKET"] = "test-bucket"
        os.environ["PRESIGNED_TTL_SECONDS"] = "1800"

    def test_handler_returns_302_with_presigned_url(self):
        import handler

        s3_client = MagicMock()
        s3_client.generate_presigned_url.return_value = "https://example.com/signed"

        with patch("handler.boto3.client", return_value=s3_client):
            response = handler.lambda_handler({}, None)

        self.assertEqual(response["statusCode"], 302)
        self.assertEqual(response["headers"]["Location"], "https://example.com/signed")
        s3_client.generate_presigned_url.assert_called_once_with(
            "get_object",
            Params={"Bucket": "test-bucket", "Key": "dashboard.html"},
            ExpiresIn=1800,
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/redirect && /tmp/dash-venv/bin/python -m unittest test_handler.py -v 2>&1`
Expected: `ModuleNotFoundError: No module named 'handler'`.

- [ ] **Step 3: Write `handler.py`**

```python
"""Redirect Lambda handler. Generates a presigned URL and returns HTTP 302."""

from __future__ import annotations

import os

import boto3


def lambda_handler(event, context):
    bucket = os.environ["DASHBOARD_BUCKET"]
    ttl = int(os.environ["PRESIGNED_TTL_SECONDS"])

    s3 = boto3.client("s3")
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": "dashboard.html"},
        ExpiresIn=ttl,
    )

    return {
        "statusCode": 302,
        "headers": {"Location": url, "Cache-Control": "no-store"},
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/lambda/redirect && /tmp/dash-venv/bin/python -m unittest test_handler.py -v 2>&1`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/lambda/redirect/
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): add redirect Lambda handler with unit test"
```

---

## Phase 4: Lambda Terraform resources

### Task 12: Refresh Lambda function + IAM role + policy + plan-mode tests

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`

- [ ] **Step 1: Add three failing assertions**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = aws_lambda_function.refresh.runtime == "python3.12"
    error_message = "Refresh Lambda must use python3.12 runtime"
  }

  assert {
    condition     = aws_lambda_function.refresh.timeout == 300 && aws_lambda_function.refresh.memory_size == 512
    error_message = "Refresh Lambda must use 512 MB memory and 5 min timeout"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.refresh.json).Statement :
      s if can(regex("ssm:|iam:Tag|iam:Untag|iam:PassRole|^\\*$", join(",", flatten([s.Action]))))
    ]) == 0
    error_message = "Refresh role must not include any ssm:*, iam:Tag*, iam:Untag*, iam:PassRole, or wildcard actions"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -15`
Expected: failure mentioning `aws_lambda_function.refresh` and `data.aws_iam_policy_document.refresh` undeclared.

- [ ] **Step 3: Add the refresh Lambda resources**

Append to `main.tf`:

```hcl
# -----------------------------------------------------------------------------
# Refresh Lambda — scheduled, read-only, renders dashboard.html to S3
# -----------------------------------------------------------------------------

data "archive_file" "refresh" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/refresh"
  output_path = "${path.module}/build/refresh.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

data "aws_iam_policy_document" "refresh_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "refresh" {
  name               = "${local.resource_prefix}-refresh"
  assume_role_policy = data.aws_iam_policy_document.refresh_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "refresh" {
  statement {
    sid    = "ReadConfigComplianceDetails"
    effect = "Allow"
    actions = [
      "config:GetComplianceDetailsByConfigRule",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:config:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:config-rule/${var.config_rule_name}",
    ]
  }

  statement {
    sid     = "ListIAMPolicies"
    effect  = "Allow"
    actions = ["iam:ListPolicies"]
    # iam:ListPolicies does not support resource-level permissions; AWS requires "*".
    resources = ["*"]
  }

  statement {
    sid     = "ReadIAMPolicyTags"
    effect  = "Allow"
    actions = ["iam:ListPolicyTags"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }

  statement {
    sid       = "GetCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"] # AWS does not support resource-level perms for this action.
  }

  statement {
    sid       = "WriteDashboardObject"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.dashboard.arn}/dashboard.html"]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}-refresh:*",
    ]
  }
}

resource "aws_iam_role_policy" "refresh" {
  name   = "${local.resource_prefix}-refresh"
  role   = aws_iam_role.refresh.id
  policy = data.aws_iam_policy_document.refresh.json
}

resource "aws_lambda_function" "refresh" {
  function_name    = "${local.resource_prefix}-refresh"
  filename         = data.archive_file.refresh.output_path
  source_code_hash = data.archive_file.refresh.output_base64sha256
  role             = aws_iam_role.refresh.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 512
  timeout          = 300

  environment {
    variables = {
      CONFIG_RULE_NAME      = var.config_rule_name
      DASHBOARD_BUCKET      = aws_s3_bucket.dashboard.id
      EXCLUDED_RESOURCE_IDS = join(",", var.excluded_resource_ids)
    }
  }

  tags = var.tags
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): add refresh Lambda + scoped IAM role"
```

---

### Task 13: Redirect Lambda + IAM role + Function URL + plan-mode tests

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`

- [ ] **Step 1: Add three failing assertions**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = aws_lambda_function.redirect.runtime == "python3.12"
    error_message = "Redirect Lambda must use python3.12 runtime"
  }

  assert {
    condition     = aws_lambda_function_url.redirect.authorization_type == "AWS_IAM"
    error_message = "Lambda Function URL must use AWS_IAM authorization (never NONE)"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.redirect.json).Statement :
      s if can(regex("config:|iam:|ssm:|s3:PutObject|s3:Delete|^\\*$", join(",", flatten([s.Action]))))
    ]) == 0
    error_message = "Redirect role must not include any config:*, iam:*, ssm:*, s3:PutObject, s3:Delete*, or wildcard actions"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -15`
Expected: failure mentioning `aws_lambda_function.redirect`, `aws_lambda_function_url.redirect`, `data.aws_iam_policy_document.redirect` undeclared.

- [ ] **Step 3: Add the redirect Lambda + Function URL resources**

Append to `main.tf`:

```hcl
# -----------------------------------------------------------------------------
# Redirect Lambda — fronted by Function URL with AWS_IAM auth
# -----------------------------------------------------------------------------

data "archive_file" "redirect" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/redirect"
  output_path = "${path.module}/build/redirect.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

resource "aws_iam_role" "redirect" {
  name               = "${local.resource_prefix}-redirect"
  assume_role_policy = data.aws_iam_policy_document.refresh_assume_role.json # same trust
  tags               = var.tags
}

data "aws_iam_policy_document" "redirect" {
  statement {
    sid       = "ReadDashboardObject"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dashboard.arn}/dashboard.html"]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}-redirect:*",
    ]
  }
}

resource "aws_iam_role_policy" "redirect" {
  name   = "${local.resource_prefix}-redirect"
  role   = aws_iam_role.redirect.id
  policy = data.aws_iam_policy_document.redirect.json
}

resource "aws_lambda_function" "redirect" {
  function_name    = "${local.resource_prefix}-redirect"
  filename         = data.archive_file.redirect.output_path
  source_code_hash = data.archive_file.redirect.output_base64sha256
  role             = aws_iam_role.redirect.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      DASHBOARD_BUCKET      = aws_s3_bucket.dashboard.id
      PRESIGNED_TTL_SECONDS = tostring(var.presigned_url_ttl_seconds)
    }
  }

  tags = var.tags
}

resource "aws_lambda_function_url" "redirect" {
  function_name      = aws_lambda_function.redirect.function_name
  authorization_type = "AWS_IAM"
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): add redirect Lambda + IAM-authed Function URL"
```

---

## Phase 5: Schedule + Logs

### Task 14: EventBridge schedule + permission + plan-mode test

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition     = aws_cloudwatch_event_rule.refresh_schedule.schedule_expression == "rate(${var.refresh_schedule_minutes} minutes)"
    error_message = "EventBridge schedule must match var.refresh_schedule_minutes"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_cloudwatch_event_rule.refresh_schedule` undeclared.

- [ ] **Step 3: Add the schedule resources**

Append to `main.tf`:

```hcl
# -----------------------------------------------------------------------------
# EventBridge schedule — invokes the refresh Lambda every N minutes
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "refresh_schedule" {
  name                = "${local.resource_prefix}-schedule"
  description         = "Periodically invoke the iam-wildcard-action-policy dashboard refresh Lambda"
  schedule_expression = "rate(${var.refresh_schedule_minutes} minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "refresh_schedule" {
  rule      = aws_cloudwatch_event_rule.refresh_schedule.name
  target_id = "refresh-lambda"
  arn       = aws_lambda_function.refresh.arn
}

resource "aws_lambda_permission" "refresh_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.refresh.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.refresh_schedule.arn
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): schedule refresh via EventBridge"
```

---

### Task 15: CloudWatch log groups + plan-mode test

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/main.tf`
- Modify: `modules/iam-wildcard-action-policy-dashboard/tests/plan.tftest.hcl`

- [ ] **Step 1: Add the failing assertion**

Append inside `run "plan_resources" { ... }`:

```hcl
  assert {
    condition = (
      aws_cloudwatch_log_group.refresh.retention_in_days == var.log_retention_days &&
      aws_cloudwatch_log_group.redirect.retention_in_days == var.log_retention_days
    )
    error_message = "Both Lambda log groups must use var.log_retention_days"
  }
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: failure mentioning `aws_cloudwatch_log_group.refresh` undeclared.

- [ ] **Step 3: Add the log groups**

Append to `main.tf`:

```hcl
# -----------------------------------------------------------------------------
# CloudWatch Logs — explicit log groups with retention (Lambda would auto-create
# without retention otherwise)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "refresh" {
  name              = "/aws/lambda/${aws_lambda_function.refresh.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "redirect" {
  name              = "/aws/lambda/${aws_lambda_function.redirect.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/{main.tf,tests/plan.tftest.hcl}
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): explicit log groups with retention"
```

---

## Phase 6: Outputs + docs + example

### Task 16: outputs.tf

**Files:**
- Modify: `modules/iam-wildcard-action-policy-dashboard/outputs.tf`

- [ ] **Step 1: Replace outputs.tf with the four outputs**

```hcl
output "dashboard_url" {
  description = "Lambda Function URL (AWS_IAM auth) — bookmark this. Stakeholders access via SigV4-signed GET; the Lambda generates a fresh presigned S3 URL and returns 302."
  value       = aws_lambda_function_url.redirect.function_url
}

output "bucket_name" {
  description = "Name of the S3 bucket containing the rendered dashboard.html. Useful for debugging or direct CLI access (`aws s3 cp`, etc.)."
  value       = aws_s3_bucket.dashboard.id
}

output "refresh_lambda_function_name" {
  description = "Name of the refresh Lambda. Run `aws lambda invoke --function-name <name>` to force a refresh ahead of schedule."
  value       = aws_lambda_function.refresh.function_name
}

output "redirect_lambda_function_name" {
  description = "Name of the redirect Lambda. For ops debugging."
  value       = aws_lambda_function.redirect.function_name
}
```

- [ ] **Step 2: Verify validates**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform validate 2>&1`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/outputs.tf
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): module outputs"
```

---

### Task 17: examples/basic/

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/examples/basic/main.tf`
- Create: `modules/iam-wildcard-action-policy-dashboard/examples/basic/variables.tf`
- Create: `modules/iam-wildcard-action-policy-dashboard/examples/basic/outputs.tf`
- Create: `modules/iam-wildcard-action-policy-dashboard/examples/basic/README.md`

- [ ] **Step 1: Write `examples/basic/main.tf`**

```hcl
provider "aws" {
  region = "us-east-1"
}

module "iam_wildcard_dashboard" {
  source = "../../"

  name_prefix               = var.name_prefix
  tags                      = var.tags
  config_rule_name          = var.config_rule_name
  refresh_schedule_minutes  = var.refresh_schedule_minutes
  presigned_url_ttl_seconds = var.presigned_url_ttl_seconds
  log_retention_days        = var.log_retention_days
  access_log_bucket         = var.access_log_bucket
  excluded_resource_ids     = var.excluded_resource_ids
}
```

- [ ] **Step 2: Write `examples/basic/variables.tf`**

```hcl
variable "name_prefix" {
  type        = string
  description = "Prefix for resource names."
  default     = "example"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}

variable "config_rule_name" {
  type        = string
  description = "Name of the deployed iam-wildcard-action-policy Config rule."
}

variable "refresh_schedule_minutes" {
  type        = number
  description = "Refresh cadence in minutes."
  default     = 15
}

variable "presigned_url_ttl_seconds" {
  type        = number
  description = "Presigned URL TTL in seconds."
  default     = 3600
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention."
  default     = 30
}

variable "access_log_bucket" {
  type        = string
  description = "Optional S3 access log target bucket."
  default     = null
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Policy IDs to filter out of the dashboard."
  default     = []
}
```

- [ ] **Step 3: Write `examples/basic/outputs.tf`**

```hcl
output "dashboard_url" {
  description = "Lambda Function URL — bookmark this."
  value       = module.iam_wildcard_dashboard.dashboard_url
}

output "bucket_name" {
  description = "Dashboard S3 bucket name."
  value       = module.iam_wildcard_dashboard.bucket_name
}

output "refresh_lambda_function_name" {
  description = "Refresh Lambda function name."
  value       = module.iam_wildcard_dashboard.refresh_lambda_function_name
}

output "redirect_lambda_function_name" {
  description = "Redirect Lambda function name."
  value       = module.iam_wildcard_dashboard.redirect_lambda_function_name
}
```

- [ ] **Step 4: Write `examples/basic/README.md`**

```markdown
# Basic example — `iam-wildcard-action-policy-dashboard`

Minimal deployment of the dashboard module pointing at an existing
`iam-wildcard-action-policy` Config rule.

## Usage

```hcl
module "iam_wildcard_dashboard" {
  source           = "../../"
  name_prefix      = "crwd"
  config_rule_name = "crwd-iam-wildcard-action-policy"
}
```

After apply, bookmark the `dashboard_url` output. Stakeholders access via
SigV4-signed GET (browser plugin, `awscurl`, or AWS CLI).
```

- [ ] **Step 5: Verify example validates**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard/examples/basic && terraform init -input=false 2>&1 | tail -3 && terraform validate 2>&1`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/examples/
git -C /home/mlopez/crwd-remediators commit -m "feat(iam-wildcard-action-policy-dashboard): basic example"
```

---

### Task 18: README.md

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/README.md`

- [ ] **Step 1: Write the full README**

```markdown
# `iam-wildcard-action-policy-dashboard`

Hosts an auto-refreshing read-only HTML dashboard for the
`iam-wildcard-action-policy` remediator. Renders the same data the operator
CLI script produces, but on a 15-minute schedule, served behind an IAM-authed
Lambda Function URL with no public exposure.

## Architecture

```
EventBridge ─▶ Refresh Lambda ─▶ S3 (private, encrypted, versioned)
                                       ▲
                  browser w/ SigV4 ─▶ Redirect Lambda (Function URL, AWS_IAM)
                                       │
                                       └─▶ 302 to presigned URL
```

- **Refresh Lambda** runs on a schedule (default 15 min). Read-only Config + IAM perms. Renders dashboard.html and uploads to S3.
- **Redirect Lambda** sits behind a Function URL with `AWS_IAM` auth. On each visit, generates a fresh short-TTL presigned URL and returns HTTP 302.
- **S3 bucket** is fully private: Block Public Access on, SSE-S3 encryption, versioning, TLS-only bucket policy, optional server-access logging.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `name_prefix` | string | ✅ | — | Prefix for all resource names |
| `tags` | map(string) | | `{}` | Tags applied to taggable resources |
| `config_rule_name` | string | ✅ | — | Wired from `module.iam_wildcard_action_policy.config_rule_name` |
| `refresh_schedule_minutes` | number | | `15` | 5–60 |
| `presigned_url_ttl_seconds` | number | | `3600` | 60–43200 |
| `log_retention_days` | number | | `30` | One of AWS-supported CloudWatch retention values |
| `access_log_bucket` | string | | `null` | If set, S3 server-access logs go here. If `null`, server-access logging is disabled and consumer accepts the resulting `s3-access-logging` finding |
| `excluded_resource_ids` | list(string) | | `[]` | Policy IDs filtered from the dashboard (Tier 2 exclusion) |

## Outputs

| Name | Description |
|---|---|
| `dashboard_url` | Lambda Function URL — bookmark this |
| `bucket_name` | S3 bucket name |
| `refresh_lambda_function_name` | Refresh Lambda name (for `aws lambda invoke` to force refresh) |
| `redirect_lambda_function_name` | Redirect Lambda name |

## Usage

```hcl
module "iam_wildcard_action_policy" {
  source      = "git::.../modules/iam-wildcard-action-policy"
  name_prefix = "crwd"
  # ...
}

module "iam_wildcard_dashboard" {
  source            = "git::.../modules/iam-wildcard-action-policy-dashboard"
  name_prefix       = "crwd"
  config_rule_name  = module.iam_wildcard_action_policy.config_rule_name
  access_log_bucket = "my-org-access-logs-bucket" # recommended
}

output "dashboard_url" {
  value = module.iam_wildcard_dashboard.dashboard_url
}
```

## Accessing the dashboard

The Function URL uses `AWS_IAM` auth — clients must SigV4-sign the request.

### Option 1: AWS CLI

```bash
URL=$(terraform output -raw dashboard_url)
awscurl --service lambda "$URL" -i | head -1
# Follow the Location header
```

### Option 2: Browser with a SigV4 extension

Install a SigV4 signing extension (e.g., "AWS SigV4 Auth" for Chrome), configure
with your AWS credentials, then bookmark the URL.

### Option 3: AWS Console federated session

If you access via SAML federation, your console session can be re-used by the
extension to sign requests.

## Security posture

| Finding | Mitigation |
|---|---|
| S3.1 / S3.2 / S3.8 | All four BPA flags enabled |
| S3.4 | SSE-S3 default encryption |
| S3.5 / CIS 2.1.5 | Bucket policy denies `aws:SecureTransport=false` |
| S3.7 | Versioning enabled |
| S3.9 | Server-access logging if `access_log_bucket` set; otherwise documented trade-off |
| Lambda.1 | Function URL uses `AWS_IAM` auth, never `NONE` |
| IAM wildcards | Plan-mode test asserts no `ssm:*`, `iam:Tag*`, `iam:Untag*`, `iam:PassRole`, or `*` actions on either Lambda role |

## Cost

At default settings (15-min refresh, ~10 stakeholder loads/day): under $0.10/month. Lambda + EventBridge are well under free tier; S3 storage and requests are negligible; CloudWatch Logs is the largest line item at ~$0.05/month.

## Forcing an early refresh

```bash
aws lambda invoke --function-name "$(terraform output -raw refresh_lambda_function_name)" /dev/null
```

## Module-CLI script parity

The Lambda's `dashboard.py` is a copy of the operator-CLI script at
`modules/iam-wildcard-action-policy/dashboard/dashboard.py`. The two are kept
in sync manually until divergence forces a shared library extraction.
```

- [ ] **Step 2: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/README.md
git -C /home/mlopez/crwd-remediators commit -m "docs(iam-wildcard-action-policy-dashboard): module README"
```

---

### Task 19: CHANGELOG.md

**Files:**
- Create: `modules/iam-wildcard-action-policy-dashboard/CHANGELOG.md`

- [ ] **Step 1: Write CHANGELOG.md**

```markdown
# Changelog

All notable changes to this module are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-04-27

### Added

- Initial release. Two-Lambda architecture (refresh + redirect) hosting an auto-refreshing read-only dashboard for the `iam-wildcard-action-policy` remediator.
- Refresh Lambda (Python 3.12, 512 MB, 5 min timeout) runs on EventBridge `rate(15 minutes)` schedule by default. Calls Config + IAM (read-only), renders HTML, uploads to S3.
- Redirect Lambda (Python 3.12, 128 MB, 10 sec timeout) fronted by a Lambda Function URL with `AWS_IAM` auth. Generates short-TTL presigned URLs and returns HTTP 302 on each invocation.
- Private S3 bucket with all four Block Public Access flags, SSE-S3 default encryption, versioning, TLS-only bucket policy, optional server-access logging.
- Plan-mode tests at `tests/plan.tftest.hcl` (10 assertions) including negative invariants on IAM action lists.
- Unit tests for both Lambda handlers using `unittest.mock`.
- Basic example at `examples/basic/`.
```

- [ ] **Step 2: Commit**

```bash
git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/CHANGELOG.md
git -C /home/mlopez/crwd-remediators commit -m "docs(iam-wildcard-action-policy-dashboard): CHANGELOG v1.0.0"
```

---

## Phase 7: Verification

### Task 20: Final verification — fmt, validate, tflint, tests, all unit tests

**Files:** none (verification only)

- [ ] **Step 1: Run terraform fmt across the module**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform fmt -recursive 2>&1`
Expected: any reformatted files printed; if none, no output.

- [ ] **Step 2: Run terraform validate**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform validate 2>&1`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Run tflint if available**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && (which tflint > /dev/null && tflint --recursive) || echo "tflint not installed — skip"`
Expected: zero issues, OR "tflint not installed — skip".

- [ ] **Step 4: Run plan-mode tests**

Run: `cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard && terraform test 2>&1 | tail -10`
Expected: `Success! 10 passed, 0 failed.`

- [ ] **Step 5: Run all Python unit tests**

Run:
```bash
cd /home/mlopez/crwd-remediators/modules/iam-wildcard-action-policy-dashboard
/tmp/dash-venv/bin/python -m unittest lambda/refresh/test_handler.py lambda/redirect/test_handler.py -v 2>&1 | tail -10
```
Expected: `OK` and `Ran 2 tests`.

- [ ] **Step 6: Stage any fmt changes and commit**

```bash
if ! git -C /home/mlopez/crwd-remediators diff --quiet modules/iam-wildcard-action-policy-dashboard/; then
  git -C /home/mlopez/crwd-remediators add modules/iam-wildcard-action-policy-dashboard/
  git -C /home/mlopez/crwd-remediators commit -m "chore(iam-wildcard-action-policy-dashboard): terraform fmt"
fi
```

---

## Phase 8: Live validation against existing iam-test deployment

### Task 21: Add dashboard module to deployments/iam-test/main.tf and apply

**Files:**
- Modify: `deployments/iam-test/main.tf`

**Pre-condition:** `deployments/iam-test/` is currently deployed in account `934791682619` from earlier session. Resources include the Config rule `crwd-test-iam-wildcard-action-policy`.

- [ ] **Step 1: Append the dashboard module block + output to main.tf**

Append to `/home/mlopez/crwd-remediators/deployments/iam-test/main.tf`:

```hcl
# =============================================================================
# Dashboard — live validation of iam-wildcard-action-policy-dashboard module
# =============================================================================

module "iam_wildcard_dashboard" {
  source = "../../modules/iam-wildcard-action-policy-dashboard"

  name_prefix               = local.prefix
  config_rule_name          = module.iam_wildcard_action_policy.config_rule_name
  refresh_schedule_minutes  = 5 # faster refresh during testing
  presigned_url_ttl_seconds = 3600
  log_retention_days        = 7

  tags = {
    Project     = "crwd-remediators-live-test"
    Environment = "test"
    ManagedBy   = "Terraform"
  }
}

output "dashboard_url" {
  value = module.iam_wildcard_dashboard.dashboard_url
}

output "dashboard_bucket_name" {
  value = module.iam_wildcard_dashboard.bucket_name
}

output "dashboard_refresh_lambda_function_name" {
  value = module.iam_wildcard_dashboard.refresh_lambda_function_name
}
```

- [ ] **Step 2: Run terraform plan, save to tfplan.live**

Run: `cd /home/mlopez/crwd-remediators/deployments/iam-test && AWS_PROFILE=default terraform plan -input=false -out=tfplan.live 2>&1 | tail -20`
Expected: `Plan: ~14 to add, 0 to change, 0 to destroy.`

- [ ] **Step 3: Apply the plan**

Run: `cd /home/mlopez/crwd-remediators/deployments/iam-test && AWS_PROFILE=default terraform apply -input=false tfplan.live 2>&1 | tail -10`
Expected: `Apply complete! Resources: ~14 added, 0 changed, 0 destroyed.` and the `dashboard_url` output is printed.

- [ ] **Step 4: Force first refresh**

Run:
```bash
cd /home/mlopez/crwd-remediators/deployments/iam-test
REFRESH_LAMBDA=$(AWS_PROFILE=default terraform output -raw dashboard_refresh_lambda_function_name)
AWS_PROFILE=default aws lambda invoke --function-name "$REFRESH_LAMBDA" /tmp/refresh.json --log-type Tail --query 'LogResult' --output text | base64 -d | tail -10
```
Expected: log shows `scanning N customer-managed policies...` and `Dashboard written` or equivalent. `/tmp/refresh.json` shows `{"status": "ok", "analyzed": <N>}`.

- [ ] **Step 5: Verify dashboard.html exists in the bucket**

Run:
```bash
BUCKET=$(AWS_PROFILE=default terraform output -raw dashboard_bucket_name)
AWS_PROFILE=default aws s3 ls "s3://$BUCKET/"
```
Expected: line listing `dashboard.html` with non-zero size.

- [ ] **Step 6: Smoke-test the redirect Lambda Function URL via signed CLI invocation**

Run:
```bash
DASHBOARD_URL=$(AWS_PROFILE=default terraform output -raw dashboard_url)
AWS_PROFILE=default aws lambda invoke \
  --function-name "$(AWS_PROFILE=default terraform output -raw dashboard_redirect_lambda_function_name 2>/dev/null || \
    AWS_PROFILE=default terraform state show module.iam_wildcard_dashboard.aws_lambda_function.redirect | grep function_name | head -1 | awk -F\\\" '{print $2}')" \
  --payload '{}' /tmp/redirect.json
cat /tmp/redirect.json
```
Expected: response body includes `"statusCode": 302` and a `Location` header URL.

- [ ] **Step 7: Download the rendered HTML to confirm it renders**

Run: `AWS_PROFILE=default aws s3 cp "s3://$BUCKET/dashboard.html" /home/mlopez/dash-deployed.html && wc -l /home/mlopez/dash-deployed.html`
Expected: file copied, ~10-200 lines depending on policy count.

- [ ] **Step 8: Commit the iam-test deployment change**

```bash
git -C /home/mlopez/crwd-remediators add deployments/iam-test/main.tf
git -C /home/mlopez/crwd-remediators commit -m "test(iam-test): wire dashboard module into live test deployment"
```

---

### Task 22: Tear down the live test deployment

**Files:** none

- [ ] **Step 1: Run terraform destroy on iam-test**

Run: `cd /home/mlopez/crwd-remediators/deployments/iam-test && AWS_PROFILE=default terraform destroy -input=false -auto-approve 2>&1 | tail -10`
**Permission note:** the harness blocked blind apply earlier. If it blocks destroy similarly, run `terraform plan -destroy -out=tfplan.destroy` first, show the plan, then `terraform apply tfplan.destroy`.

Expected: `Destroy complete! Resources: ~58 destroyed.`

- [ ] **Step 2: Verify zero resources remain in state**

Run: `cd /home/mlopez/crwd-remediators/deployments/iam-test && AWS_PROFILE=default terraform state list 2>&1`
Expected: empty output.

- [ ] **Step 3: Clean stray planfiles**

Run: `rm -f /home/mlopez/crwd-remediators/deployments/iam-test/tfplan.live /home/mlopez/crwd-remediators/deployments/iam-test/tfplan.destroy`

---

## Phase 9: Open the PR

### Task 23: Push branch + open draft PR

**Files:** none

- [ ] **Step 1: Push the feature branch to origin (GitHub)**

Run: `git -C /home/mlopez/crwd-remediators push -u origin feat/iam-wildcard-dashboard-deploy 2>&1`
Expected: `branch 'feat/iam-wildcard-dashboard-deploy' set up to track 'origin/feat/iam-wildcard-dashboard-deploy'`.

- [ ] **Step 2: Open the draft PR**

Run:
```bash
gh pr create --repo lopmigtech/crwd-remediators --draft \
  --base main \
  --head feat/iam-wildcard-dashboard-deploy \
  --title "Add iam-wildcard-action-policy-dashboard module" \
  --body "$(cat <<'EOF'
## Summary

Adds sibling Terraform module `modules/iam-wildcard-action-policy-dashboard/` — a hosted version of the operator-CLI dashboard introduced in PR #1.

- Two-Lambda architecture: refresh (scheduled, read-only) + redirect (Function URL, IAM-authed, presigned URL generator).
- Private S3 bucket with all four BPA flags, SSE-S3, versioning, TLS-only, optional access logging.
- 10 plan-mode test assertions including negative IAM invariants.
- Unit tests for both Lambda handlers.
- Live-validated against `deployments/iam-test/` (deployment + smoke test recorded in commit history; teardown also performed).

## Spec
`docs/superpowers/specs/2026-04-27-iam-wildcard-dashboard-design.md`

## Test plan
- [x] `terraform fmt` clean
- [x] `terraform validate` passes
- [x] `terraform test` — 10/10 plan-mode assertions pass
- [x] Python `unittest` — 2/2 handler tests pass
- [x] Live apply against test deployment, dashboard.html rendered, Function URL returns 302

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
Expected: PR URL printed.

- [ ] **Step 3: Verify PR exists**

Run: `gh pr view --repo lopmigtech/crwd-remediators --json number,state,title,url --jq '{number, state, title, url}'`
Expected: JSON showing the new PR with `state: "OPEN"` and `state: "DRAFT"` (drafts are still OPEN state).

---

## Self-Review Notes

**Spec coverage check** — every spec section has implementing tasks:

| Spec section | Tasks |
|---|---|
| Architecture (refresh + redirect Lambdas + S3) | 12, 13 (Lambdas) + 4-9 (S3) |
| Module Layout | 2 (scaffold) + 17 (example) |
| Inputs | 3 |
| Outputs | 16 |
| Resource naming | 2 (locals.resource_prefix), referenced throughout |
| Lambda runtime + packaging | 12, 13 (archive_file + runtime + memory + timeout) |
| Why copy dashboard.py | 10 (`cp` step) + README in 18 |
| Refresh + redirect env vars | 12, 13 (environment blocks) |
| IAM (no wildcard, dynamic partition) | 12, 13 (policy documents) |
| Negative invariants | 12, 13 (assertions) |
| Security findings posture | 4-9 (S3 mitigations) + 13 (Function URL IAM auth) |
| Cost | covered by test/free-tier-fitting choices |
| Testing — plan mode (≥5) | 10 assertions across 4-15 |
| Testing — manual smoke test | 21 |
| Future work / out of scope | spec, no tasks |

**Placeholder scan** — no TBD/TODO/"add appropriate" patterns. All test code is concrete. All commands are exact.

**Type/name consistency** — resource names used consistently:
- `aws_s3_bucket.dashboard`, `aws_s3_bucket_public_access_block.dashboard`, `aws_s3_bucket_server_side_encryption_configuration.dashboard`, `aws_s3_bucket_versioning.dashboard`, `aws_s3_bucket_policy.dashboard`, `aws_s3_bucket_logging.dashboard`
- `aws_lambda_function.refresh`, `aws_iam_role.refresh`, `data.aws_iam_policy_document.refresh`, `aws_iam_role_policy.refresh`, `aws_cloudwatch_log_group.refresh`
- `aws_lambda_function.redirect`, `aws_iam_role.redirect`, `data.aws_iam_policy_document.redirect`, `aws_iam_role_policy.redirect`, `aws_lambda_function_url.redirect`, `aws_cloudwatch_log_group.redirect`
- `aws_cloudwatch_event_rule.refresh_schedule`, `aws_cloudwatch_event_target.refresh_schedule`, `aws_lambda_permission.refresh_schedule`
- Local: `local.resource_prefix`, `local.bucket_name`
- Variables match between module and example.

**Scope check** — single module, single feature, single PR. Live validation + teardown are appropriate scope additions to verify the module works.
