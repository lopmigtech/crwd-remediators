import json
import urllib.parse
import datetime
import boto3


config_client = boto3.client('config')


def lambda_handler(event, context):
    """Evaluate IAM customer-managed policies for <service>:* wildcard actions."""
    invoking_event = json.loads(event['invokingEvent'])
    configuration_item = invoking_event.get('configurationItem', {})
    result_token = event.get('resultToken', 'TESTMODE')

    # Only evaluate customer-managed policies
    resource_type = configuration_item.get('resourceType', '')
    if resource_type != 'AWS::IAM::Policy':
        return put_evaluation(event, configuration_item, 'NOT_APPLICABLE', result_token)

    # Get the policy configuration
    config = configuration_item.get('configuration', {})

    # Skip AWS-managed policies (they have arn:aws:iam::aws:policy/ prefix)
    arn = configuration_item.get('ARN', '')
    if ':aws:policy/' in arn or '::aws:policy/' in arn:
        return put_evaluation(event, configuration_item, 'NOT_APPLICABLE', result_token)

    # Get the policy document from the default version
    policy_versions = config.get('policyVersionList', [])
    default_doc = None
    for version in policy_versions:
        if version.get('isDefaultVersion', False):
            doc = version.get('document', '{}')
            if isinstance(doc, str):
                # Config delivers policy documents URL-encoded
                try:
                    decoded = urllib.parse.unquote(doc)
                    default_doc = json.loads(decoded) if decoded else None
                except (json.JSONDecodeError, ValueError):
                    try:
                        default_doc = json.loads(doc) if doc else None
                    except (json.JSONDecodeError, ValueError):
                        default_doc = None
            else:
                default_doc = doc
            break

    if not default_doc:
        return put_evaluation(event, configuration_item, 'NOT_APPLICABLE', result_token)

    # Check for <service>:* wildcard actions
    statements = default_doc.get('Statement', [])
    if isinstance(statements, dict):
        statements = [statements]

    wildcard_services = []
    for stmt in statements:
        if stmt.get('Effect') != 'Allow':
            continue
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        for action in actions:
            if isinstance(action, str) and action.endswith(':*') and action != '*':
                service = action.split(':')[0]
                if service not in wildcard_services:
                    wildcard_services.append(service)

    if wildcard_services:
        annotation = f"Policy has wildcard actions for: {', '.join(wildcard_services)}"
        return put_evaluation(event, configuration_item, 'NON_COMPLIANT', result_token, annotation)

    return put_evaluation(event, configuration_item, 'COMPLIANT', result_token)


def put_evaluation(event, configuration_item, compliance_type, result_token, annotation=''):
    """Submit evaluation result back to AWS Config via PutEvaluations API."""
    evaluation = {
        'ComplianceResourceType': configuration_item.get('resourceType', 'AWS::IAM::Policy'),
        'ComplianceResourceId': configuration_item.get('resourceId', ''),
        'ComplianceType': compliance_type,
        'Annotation': (annotation[:255] if annotation else 'Evaluated by iam-wildcard-action-policy'),
        'OrderingTimestamp': configuration_item.get(
            'configurationItemCaptureTime',
            datetime.datetime.now(datetime.timezone.utc).isoformat()
        ),
    }

    config_client.put_evaluations(
        Evaluations=[evaluation],
        ResultToken=result_token,
    )

    return {
        'compliance_type': compliance_type,
        'annotation': evaluation['Annotation'],
    }
