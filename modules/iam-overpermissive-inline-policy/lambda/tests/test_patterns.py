from patterns import classify_statement


def test_full_wildcard_classified_as_full():
    stmt = {"Effect": "Allow", "Action": "*"}
    assert classify_statement(stmt) == "full"


def test_service_wildcard_classified_as_service():
    stmt = {"Effect": "Allow", "Action": "s3:*"}
    assert classify_statement(stmt) == "service"


def test_verb_prefix_wildcard_returns_none():
    stmt = {"Effect": "Allow", "Action": "s3:Get*"}
    assert classify_statement(stmt) is None


def test_specific_action_returns_none():
    stmt = {"Effect": "Allow", "Action": "s3:GetObject"}
    assert classify_statement(stmt) is None


def test_missing_action_returns_none():
    stmt = {"Effect": "Allow"}
    assert classify_statement(stmt) is None


def test_deny_statement_returns_none_even_with_full_wildcard():
    stmt = {"Effect": "Deny", "Action": "*"}
    assert classify_statement(stmt) is None


def test_notaction_statement_returns_none():
    stmt = {"Effect": "Allow", "NotAction": "*"}
    assert classify_statement(stmt) is None
