"""boto3 guardrail: registers a before-parameter-build hook on IAM write
operations that carry a PolicyDocument, and raises PolicyValidationError
before the request is signed and sent to AWS.

Usage:
    import boto3_guardrail
    boto3_guardrail.install()

    import boto3
    iam = boto3.client("iam")
    iam.create_policy(...)   # Will raise PolicyValidationError on bad input
"""

from __future__ import annotations

import boto3

from validator import PolicyValidationError, validate_policy_document


GUARDED_OPERATIONS: frozenset[str] = frozenset(
    {
        "CreatePolicy",
        "CreatePolicyVersion",
        "PutRolePolicy",
        "PutUserPolicy",
        "PutGroupPolicy",
    }
)


def _make_handler(operation_name: str):
    def _handler(params, **_kwargs):
        policy_doc = params.get("PolicyDocument")
        if policy_doc is None:
            return
        violations = validate_policy_document(policy_doc)
        if violations:
            raise PolicyValidationError(violations, operation=operation_name)

    return _handler


def install_on_session(session: boto3.session.Session) -> None:
    """Register handlers on a specific boto3 session."""
    for op in GUARDED_OPERATIONS:
        session.events.register(
            f"before-parameter-build.iam.{op}",
            _make_handler(op),
        )


def install() -> None:
    """Monkey-patch boto3.session.Session so every new Session (including the
    default one used by boto3.client / boto3.resource) gets the handlers."""
    original_init = boto3.session.Session.__init__

    def patched_init(self, *args, **kwargs):
        original_init(self, *args, **kwargs)
        install_on_session(self)

    boto3.session.Session.__init__ = patched_init  # type: ignore[method-assign]

    # Also retrofit the default session if it already exists.
    default = boto3.DEFAULT_SESSION
    if default is not None:
        install_on_session(default)
