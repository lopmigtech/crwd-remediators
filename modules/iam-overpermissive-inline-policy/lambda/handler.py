import datetime
import json

import boto3

from evaluator import evaluate


config_client = boto3.client("config")


def lambda_handler(event, context):
    result = evaluate(event)
    invoking_event = json.loads(event["invokingEvent"])
    config_item = invoking_event.get("configurationItem", {})
    config_client.put_evaluations(
        Evaluations=[
            {
                "ComplianceResourceType": config_item.get("resourceType", ""),
                "ComplianceResourceId": config_item.get("resourceId", ""),
                "ComplianceType": result["compliance_type"],
                "Annotation": result["annotation"][:255],
                "OrderingTimestamp": config_item.get(
                    "configurationItemCaptureTime",
                    datetime.datetime.now(datetime.timezone.utc).isoformat(),
                ),
            }
        ],
        ResultToken=event.get("resultToken", "TESTMODE"),
    )
    return result
