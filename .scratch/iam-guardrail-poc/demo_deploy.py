"""Tower-emulating deployment script.

Runs boto3 calls against IAM that mimic what Ansible Tower would execute when
deploying a policy from CMDB content. The guardrail intercepts violations
before any AWS call leaves this process.

Usage:
    python demo_deploy.py good
    python demo_deploy.py bad-full
    python demo_deploy.py bad-scoped
    python demo_deploy.py bad-notaction
    python demo_deploy.py bad-mixed
    python demo_deploy.py inline   # PutRolePolicy form

Exit codes:
    0  policy created (or "good" scenario succeeded)
    1  guardrail rejected the policy (PolicyValidationError)
    2  AWS API error (network, credentials, permissions, name conflict, etc.)
    3  usage error
"""

from __future__ import annotations

import json
import sys

import boto3

import boto3_guardrail
from validator import PolicyValidationError

boto3_guardrail.install()


GOOD_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject"],
            "Resource": "arn:aws:s3:::my-bucket/*",
        }
    ],
}

BAD_FULL_WILDCARD = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "*",
            "Resource": "*",
        }
    ],
}

BAD_SCOPED_WILDCARD = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["ec2:*", "lambda:*"],
            "Resource": "*",
        }
    ],
}

BAD_NOT_ACTION = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "NotAction": "iam:DeleteUser",
            "Resource": "*",
        }
    ],
}

BAD_MIXED = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["s3:GetObject"],
            "Resource": "arn:aws:s3:::ok-bucket/*",
        },
        {
            "Effect": "Allow",
            "Action": ["iam:*", "kms:*"],
            "Resource": "*",
        },
    ],
}


SCENARIOS: dict[str, tuple[str, dict, str]] = {
    "good": ("PoC-Good-Policy", GOOD_POLICY, "managed"),
    "bad-full": ("PoC-FullWildcard", BAD_FULL_WILDCARD, "managed"),
    "bad-scoped": ("PoC-ScopedWildcard", BAD_SCOPED_WILDCARD, "managed"),
    "bad-notaction": ("PoC-NotAction", BAD_NOT_ACTION, "managed"),
    "bad-mixed": ("PoC-Mixed", BAD_MIXED, "managed"),
    "inline": ("PoC-Inline-BadPolicy", BAD_SCOPED_WILDCARD, "inline"),
}


def deploy_managed(name: str, document: dict) -> None:
    iam = boto3.client("iam")
    print(f"[Tower-emulated] CreatePolicy(name={name})")
    iam.create_policy(
        PolicyName=name,
        PolicyDocument=json.dumps(document),
    )
    print(f"  [SUCCESS] Managed policy '{name}' created.")


def deploy_inline(role_name: str, policy_name: str, document: dict) -> None:
    iam = boto3.client("iam")
    print(f"[Tower-emulated] PutRolePolicy(role={role_name}, policy={policy_name})")
    iam.put_role_policy(
        RoleName=role_name,
        PolicyName=policy_name,
        PolicyDocument=json.dumps(document),
    )
    print(f"  [SUCCESS] Inline policy '{policy_name}' attached to role '{role_name}'.")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in SCENARIOS:
        print(f"Usage: {argv[0]} {{{'|'.join(SCENARIOS)}}}", file=sys.stderr)
        return 3

    name, document, kind = SCENARIOS[argv[1]]

    try:
        if kind == "managed":
            deploy_managed(name, document)
        elif kind == "inline":
            role_name = argv[2] if len(argv) > 2 else "PoC-Existing-Role"
            deploy_inline(role_name, name, document)
        return 0
    except PolicyValidationError as e:
        print("  [BLOCKED] Guardrail rejected the deploy:", file=sys.stderr)
        for line in str(e).splitlines():
            print(f"  {line}", file=sys.stderr)
        print("\n  [STRUCTURED_ERROR_CODE]", file=sys.stderr)
        print(json.dumps(e.to_dict(), indent=2), file=sys.stderr)
        return 1
    except Exception as e:
        print(f"  [AWS_ERROR] {type(e).__name__}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
