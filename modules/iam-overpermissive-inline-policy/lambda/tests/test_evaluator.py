import json
import urllib.parse

from evaluator import evaluate


def test_role_with_inline_full_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE12345",
                "resourceName": "MyLambdaRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "OverpermissiveInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_role_with_inline_specific_actions_only_is_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject"],
                "Resource": "*",
            }
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE99999",
                "resourceName": "ScopedRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "ScopedInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "COMPLIANT"


def test_unsupported_resource_type_is_not_applicable():
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::S3::Bucket",
                "resourceId": "my-bucket",
                "resourceName": "my-bucket",
                "configuration": {},
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NOT_APPLICABLE"


def test_user_with_inline_full_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::User",
                "resourceId": "AIDAEXAMPLE12345",
                "resourceName": "MyUser",
                "configuration": {
                    "userPolicyList": [
                        {
                            "policyName": "OverpermissiveInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_group_with_inline_full_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Group",
                "resourceId": "AGPAEXAMPLE12345",
                "resourceName": "MyGroup",
                "configuration": {
                    "groupPolicyList": [
                        {
                            "policyName": "OverpermissiveInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_role_with_action_as_list_containing_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject", "*"],
                "Resource": "*",
            }
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE55555",
                "resourceName": "MixedActionsRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "MixedInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_role_with_plain_unencoded_policy_document_is_evaluated_correctly():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "*", "Resource": "*"}
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE77777",
                "resourceName": "PlainDocRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "PlainInline",
                            "policyDocument": policy_document,
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_role_with_inline_service_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "s3:*", "Resource": "*"}
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE66666",
                "resourceName": "ServiceWildcardRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "ServiceWildcardInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"


def test_role_with_multi_statement_policy_only_middle_with_wildcard_is_non_compliant():
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "*"},
            {"Effect": "Allow", "Action": "*", "Resource": "*"},
            {"Effect": "Allow", "Action": "s3:PutObject", "Resource": "*"},
        ],
    })
    event = {
        "invokingEvent": json.dumps({
            "configurationItem": {
                "resourceType": "AWS::IAM::Role",
                "resourceId": "AROAEXAMPLE88888",
                "resourceName": "MultiStmtRole",
                "configuration": {
                    "rolePolicyList": [
                        {
                            "policyName": "MultiStmtInline",
                            "policyDocument": urllib.parse.quote(policy_document),
                        }
                    ]
                },
            }
        }),
        "resultToken": "TESTMODE",
    }

    result = evaluate(event)

    assert result["compliance_type"] == "NON_COMPLIANT"
