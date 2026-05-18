import json
import urllib.parse

from patterns import classify_statement


RESOURCE_TYPE_TO_FIELD = {
    "AWS::IAM::Role": "rolePolicyList",
    "AWS::IAM::User": "userPolicyList",
    "AWS::IAM::Group": "groupPolicyList",
}


def evaluate(event):
    invoking_event = json.loads(event["invokingEvent"])
    config_item = invoking_event.get("configurationItem", {})
    resource_type = config_item.get("resourceType", "")

    if resource_type not in RESOURCE_TYPE_TO_FIELD:
        return {
            "compliance_type": "NOT_APPLICABLE",
            "annotation": f"Resource type {resource_type} is not in scope",
        }

    field = RESOURCE_TYPE_TO_FIELD[resource_type]
    inline_policies = config_item.get("configuration", {}).get(field, [])

    for inline in inline_policies:
        document = json.loads(urllib.parse.unquote(inline.get("policyDocument", "{}")))
        for statement in document.get("Statement", []):
            pattern = classify_statement(statement)
            if pattern is not None:
                return {
                    "compliance_type": "NON_COMPLIANT",
                    "annotation": f"Inline policy {inline.get('policyName')} contains {pattern} wildcard",
                }

    return {"compliance_type": "COMPLIANT", "annotation": "No findings"}
