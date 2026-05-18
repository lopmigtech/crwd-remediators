from resource_ids import parse, format_id


def test_parse_composite_with_inline_policy_name():
    assert parse("role/MyLambda#OverPerm") == ("role", "MyLambda", "OverPerm")


def test_parse_composite_without_inline_policy_name():
    assert parse("role/MyLambda") == ("role", "MyLambda", None)


def test_format_with_inline_policy_name():
    assert format_id("role", "MyLambda", "OverPerm") == "role/MyLambda#OverPerm"


def test_format_without_inline_policy_name():
    assert format_id("role", "MyLambda", None) == "role/MyLambda"
