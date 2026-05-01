"""Refresh Lambda handler. Renders the dashboard and uploads to S3."""

from __future__ import annotations

import os

import boto3

import dashboard


def lambda_handler(event, context):
    config_rule = os.environ["CONFIG_RULE_NAME"]
    inline_rule = os.environ.get("INLINE_CONFIG_RULE_NAME", "")
    fullwildcard_rule = os.environ.get("FULLWILDCARD_CONFIG_RULE_NAME", "")
    bucket = os.environ["DASHBOARD_BUCKET"]
    excluded_policies = {s for s in os.environ.get("EXCLUDED_RESOURCE_IDS", "").split(",") if s}
    excluded_principals = {s for s in os.environ.get("EXCLUDED_PRINCIPAL_IDS", "").split(",") if s}

    sess = boto3.session.Session()
    cfg = sess.client("config")
    iam = sess.client("iam")
    sts = sess.client("sts")
    s3 = sess.client("s3")

    ident = sts.get_caller_identity()
    noncompliant = [
        n for n in dashboard.get_noncompliant_policies(cfg, config_rule)
        if n["resource_id"] not in excluded_policies
    ]
    fleet = [
        p for p in dashboard.scan_fleet_tags(iam)
        if p["policy_id"] not in excluded_policies
    ]

    inline_findings = []
    if inline_rule:
        inline_findings = [
            p for p in dashboard.scan_principal_inline_tags(iam)
            if f"{p['principal_kind'].lower()}/{p['principal_name']}" not in excluded_principals
        ]

    state = dashboard.build_state(
        rule_name=config_rule,
        noncompliant=noncompliant,
        fleet=fleet,
        executions=None,
        account_id=ident.get("Account", "unknown"),
        region=sess.region_name or "unknown",
        inline_rule_name=inline_rule,
        fullwildcard_rule_name=fullwildcard_rule,
        inline_findings=inline_findings,
    )
    html = dashboard.render_html(state)

    s3.put_object(
        Bucket=bucket,
        Key="dashboard.html",
        Body=html.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
        ServerSideEncryption="AES256",
    )

    return {"status": "ok", "analyzed": state["totals"]["analyzed"]}
