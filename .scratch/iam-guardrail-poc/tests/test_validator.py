"""Unit tests for the policy validator.

Run from the PoC directory:
    pytest tests/
"""

from __future__ import annotations

import os
import sys

# Make validator.py importable when pytest discovers tests from this folder.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import pytest  # noqa: E402

from validator import (  # noqa: E402
    PolicyValidationError,
    Violation,
    validate_policy_document,
)


# ---------- Acceptance cases (should produce zero violations) ----------


def test_scoped_action_list_passes():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject"],
                "Resource": "arn:aws:s3:::bucket/*",
            }
        ],
    }
    assert validate_policy_document(doc) == []


def test_deny_with_wildcard_passes():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Deny",
                "Action": "*",
                "Resource": "*",
                "Condition": {"Bool": {"aws:MultiFactorAuthPresent": "false"}},
            }
        ],
    }
    assert validate_policy_document(doc) == []


def test_not_action_with_deny_passes():
    """NotAction + Deny is the legitimate deny-all-except idiom."""
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Deny",
                "NotAction": "iam:DeleteUser",
                "Resource": "*",
            }
        ],
    }
    assert validate_policy_document(doc) == []


def test_action_string_form_passes():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "s3:GetObject",
                "Resource": "arn:aws:s3:::bucket/*",
            }
        ],
    }
    assert validate_policy_document(doc) == []


# ---------- Rejection cases ----------


def test_full_wildcard_blocked():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 1
    assert violations[0].rule == "BLOCKED_ACTION_PATTERN"
    assert violations[0].offending_value == "*"
    assert violations[0].statement_index == 0


def test_scoped_wildcards_blocked():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["ec2:*", "lambda:*"],
                "Resource": "*",
            }
        ],
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 2
    assert {v.offending_value for v in violations} == {"ec2:*", "lambda:*"}
    assert all(v.rule == "BLOCKED_ACTION_PATTERN" for v in violations)


def test_iam_wildcard_blocked():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "iam:*", "Resource": "*"}
        ],
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 1
    assert violations[0].offending_value == "iam:*"


def test_not_action_with_allow_blocked():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "NotAction": "iam:DeleteUser",
                "Resource": "*",
            }
        ],
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 1
    assert violations[0].rule == "NOT_ACTION_WITH_ALLOW"


def test_mixed_good_and_bad_statements():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject"],
                "Resource": "arn:aws:s3:::ok/*",
            },
            {
                "Effect": "Allow",
                "Action": ["iam:*", "kms:*"],
                "Resource": "*",
            },
        ],
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 2
    assert all(v.statement_index == 1 for v in violations)
    assert {v.offending_value for v in violations} == {"iam:*", "kms:*"}


# ---------- Input shape robustness ----------


def test_string_input_is_parsed():
    doc_str = (
        '{"Version":"2012-10-17","Statement":'
        '[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
    )
    violations = validate_policy_document(doc_str)
    assert len(violations) == 1


def test_malformed_json_returns_violation():
    violations = validate_policy_document("{not valid json")
    assert len(violations) == 1
    assert violations[0].rule == "MALFORMED_JSON"


def test_single_statement_object_not_list():
    """AWS accepts Statement as a single object; validator must too."""
    doc = {
        "Version": "2012-10-17",
        "Statement": {"Effect": "Allow", "Action": "*", "Resource": "*"},
    }
    violations = validate_policy_document(doc)
    assert len(violations) == 1


def test_unsupported_input_type_returns_violation():
    violations = validate_policy_document(12345)  # type: ignore[arg-type]
    assert len(violations) == 1
    assert violations[0].rule == "UNSUPPORTED_TYPE"


# ---------- Configurability ----------


def test_custom_blocked_patterns_extends_default():
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "athena:*", "Resource": "*"}
        ],
    }
    # Default does not include athena:*
    assert validate_policy_document(doc) == []
    # Custom list includes it
    violations = validate_policy_document(doc, blocked_patterns=["athena:*"])
    assert len(violations) == 1


def test_custom_blocked_patterns_can_relax():
    """Empty deny-list = nothing blocked (useful for testing)."""
    doc = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    }
    assert validate_policy_document(doc, blocked_patterns=[]) == []


# ---------- Error structure ----------


def test_validation_error_contains_structured_findings():
    violations = [
        Violation(
            rule="BLOCKED_ACTION_PATTERN",
            statement_index=0,
            detail="x",
            offending_value="*",
        ),
        Violation(
            rule="BLOCKED_ACTION_PATTERN",
            statement_index=1,
            detail="y",
            offending_value="ec2:*",
        ),
    ]
    err = PolicyValidationError(violations, operation="CreatePolicy")
    payload = err.to_dict()
    assert payload["error"] == "PolicyValidationError"
    assert payload["operation"] == "CreatePolicy"
    assert payload["violation_count"] == 2
    assert len(payload["violations"]) == 2
    assert payload["violations"][0]["offending_value"] == "*"


def test_validation_error_str_lists_each_violation():
    violations = [
        Violation(
            rule="BLOCKED_ACTION_PATTERN",
            statement_index=0,
            detail="x",
            offending_value="*",
        )
    ]
    err = PolicyValidationError(violations, operation="CreatePolicy")
    text = str(err)
    assert "1 violation" in text
    assert "CreatePolicy" in text
    assert "BLOCKED_ACTION_PATTERN" in text
    assert "Statement[0]" in text


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
