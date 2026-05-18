"""Integration test that exercises the boto3 hook end-to-end without ever
hitting AWS. Uses botocore's stubber + the before-parameter-build phase of
the request lifecycle, which fires before signing/sending.
"""

from __future__ import annotations

import json
import os
import sys

import boto3
import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import boto3_guardrail  # noqa: E402
from validator import PolicyValidationError  # noqa: E402


@pytest.fixture
def session_with_guardrail():
    """A fresh session with the guardrail registered, no monkey-patch leakage."""
    session = boto3.session.Session(
        aws_access_key_id="AKIATEST",
        aws_secret_access_key="secret",
        region_name="us-east-1",
    )
    boto3_guardrail.install_on_session(session)
    return session


def _bad_doc() -> str:
    return json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}],
        }
    )


def _good_doc() -> str:
    return json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["s3:GetObject"],
                    "Resource": "arn:aws:s3:::b/*",
                }
            ],
        }
    )


def test_create_policy_blocked(session_with_guardrail):
    iam = session_with_guardrail.client("iam")
    with pytest.raises(PolicyValidationError) as exc:
        iam.create_policy(PolicyName="x", PolicyDocument=_bad_doc())
    assert exc.value.operation == "CreatePolicy"
    assert any(v.offending_value == "*" for v in exc.value.violations)


def test_create_policy_version_blocked(session_with_guardrail):
    iam = session_with_guardrail.client("iam")
    with pytest.raises(PolicyValidationError) as exc:
        iam.create_policy_version(
            PolicyArn="arn:aws:iam::123456789012:policy/x",
            PolicyDocument=_bad_doc(),
        )
    assert exc.value.operation == "CreatePolicyVersion"


def test_put_role_policy_blocked(session_with_guardrail):
    iam = session_with_guardrail.client("iam")
    with pytest.raises(PolicyValidationError):
        iam.put_role_policy(
            RoleName="some-role",
            PolicyName="inline-x",
            PolicyDocument=_bad_doc(),
        )


def test_put_user_policy_blocked(session_with_guardrail):
    iam = session_with_guardrail.client("iam")
    with pytest.raises(PolicyValidationError):
        iam.put_user_policy(
            UserName="some-user",
            PolicyName="inline-x",
            PolicyDocument=_bad_doc(),
        )


def test_put_group_policy_blocked(session_with_guardrail):
    iam = session_with_guardrail.client("iam")
    with pytest.raises(PolicyValidationError):
        iam.put_group_policy(
            GroupName="some-group",
            PolicyName="inline-x",
            PolicyDocument=_bad_doc(),
        )


def test_good_policy_does_not_raise_in_hook(session_with_guardrail):
    """The hook should let a good policy through. The call will then fail at
    signing/sending because of fake creds, but the failure must NOT come from
    PolicyValidationError."""
    iam = session_with_guardrail.client("iam")
    with pytest.raises(Exception) as exc:
        iam.create_policy(PolicyName="ok", PolicyDocument=_good_doc())
    assert not isinstance(exc.value, PolicyValidationError)


def test_unguarded_operation_passes_through(session_with_guardrail):
    """An IAM action without a PolicyDocument parameter should be untouched
    by the hook (it'll fail at AWS for fake creds, not at the hook)."""
    iam = session_with_guardrail.client("iam")
    with pytest.raises(Exception) as exc:
        iam.list_users()
    assert not isinstance(exc.value, PolicyValidationError)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
