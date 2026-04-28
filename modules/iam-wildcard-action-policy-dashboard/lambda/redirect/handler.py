"""Redirect Lambda handler. Generates a presigned URL and returns HTTP 302."""

from __future__ import annotations

import os

import boto3


def lambda_handler(event, context):
    bucket = os.environ["DASHBOARD_BUCKET"]
    ttl = int(os.environ["PRESIGNED_TTL_SECONDS"])

    s3 = boto3.client("s3")
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": "dashboard.html"},
        ExpiresIn=ttl,
    )

    return {
        "statusCode": 302,
        "headers": {"Location": url, "Cache-Control": "no-store"},
    }
