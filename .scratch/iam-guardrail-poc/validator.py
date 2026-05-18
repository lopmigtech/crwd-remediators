"""Pure-Python validator for IAM policy documents.

Runs offline. No AWS API calls. The same logic is invoked from the boto3
guardrail hook and (later, if needed) from a server-side Lambda.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any, Iterable


DEFAULT_BLOCKED_PATTERNS: frozenset[str] = frozenset(
    {
        "*",
        "iam:*",
        "kms:*",
        "secretsmanager:*",
        "s3:*",
        "ec2:*",
        "lambda:*",
        "rds:*",
        "dynamodb:*",
        "organizations:*",
        "sts:*",
    }
)


@dataclass
class Violation:
    rule: str
    statement_index: int
    detail: str
    offending_value: str


class PolicyValidationError(Exception):
    """Raised when a policy document fails the guardrail's checks."""

    def __init__(self, violations: list[Violation], operation: str = ""):
        self.violations = violations
        self.operation = operation
        super().__init__(self._format())

    def _format(self) -> str:
        header = f"PolicyValidationError: {len(self.violations)} violation(s)"
        if self.operation:
            header += f" during {self.operation}"
        lines = [header]
        for i, v in enumerate(self.violations, start=1):
            lines.append(
                f"  [{i}] {v.rule} at Statement[{v.statement_index}]: {v.detail}"
            )
            lines.append(f"      offending_value={v.offending_value!r}")
        return "\n".join(lines)

    def to_dict(self) -> dict[str, Any]:
        return {
            "error": "PolicyValidationError",
            "operation": self.operation,
            "violation_count": len(self.violations),
            "violations": [asdict(v) for v in self.violations],
        }


def validate_policy_document(
    policy_doc: str | dict,
    blocked_patterns: Iterable[str] | None = None,
) -> list[Violation]:
    """Validate a policy document. Returns a list of violations (empty == compliant)."""
    blocked = (
        frozenset(blocked_patterns)
        if blocked_patterns is not None
        else DEFAULT_BLOCKED_PATTERNS
    )

    if isinstance(policy_doc, str):
        try:
            parsed = json.loads(policy_doc)
        except json.JSONDecodeError as exc:
            return [
                Violation(
                    rule="MALFORMED_JSON",
                    statement_index=-1,
                    detail=f"Policy document is not valid JSON: {exc}",
                    offending_value=policy_doc[:200],
                )
            ]
    elif isinstance(policy_doc, dict):
        parsed = policy_doc
    else:
        return [
            Violation(
                rule="UNSUPPORTED_TYPE",
                statement_index=-1,
                detail=f"Policy document must be str or dict, got {type(policy_doc).__name__}",
                offending_value=str(type(policy_doc)),
            )
        ]

    violations: list[Violation] = []

    statements = parsed.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]

    for idx, stmt in enumerate(statements):
        if not isinstance(stmt, dict) or stmt.get("Effect") != "Allow":
            continue

        actions = stmt.get("Action", [])
        if isinstance(actions, str):
            actions = [actions]

        for action in actions:
            if action in blocked:
                violations.append(
                    Violation(
                        rule="BLOCKED_ACTION_PATTERN",
                        statement_index=idx,
                        detail=(
                            f"Action '{action}' is in the blocked-pattern list. "
                            "Use a scoped action list (e.g. 's3:GetObject') instead."
                        ),
                        offending_value=action,
                    )
                )

        if "NotAction" in stmt:
            not_action_value = stmt["NotAction"]
            violations.append(
                Violation(
                    rule="NOT_ACTION_WITH_ALLOW",
                    statement_index=idx,
                    detail=(
                        "Statement uses 'NotAction' with Effect:Allow. "
                        "This grants every action except the listed ones, which is "
                        "almost always overly permissive. Use 'Action' with an "
                        "explicit list instead."
                    ),
                    offending_value=str(not_action_value),
                )
            )

    return violations
