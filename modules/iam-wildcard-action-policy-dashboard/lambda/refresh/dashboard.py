#!/usr/bin/env python3
"""Stakeholder dashboard for the iam-wildcard-action-policy remediator.

Automates runbook Steps 3-6 (start SSM full-analysis, wait, scan fleet tags,
pull remediation detail) and renders a standalone HTML dashboard.

Subcommands:
  start    -- Step 3: start SSM full-analysis on top N NON_COMPLIANT policies.
  watch    -- Step 4: poll SSM executions until terminal.
  collect  -- Steps 5+6: scan fleet IAM tags and render HTML (no SSM starts).
  run      -- End-to-end 3->6 and render HTML.
  render   -- Render HTML from a previously-dumped state JSON (offline smoke test).

Credentials: standard boto3 chain (env, --profile, instance role).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import html
import json
import sys
import time
from datetime import datetime, timezone
from typing import Any

try:
    import boto3
    from botocore.config import Config as BotoConfig
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:
    boto3 = None
    BotoConfig = None

    class ClientError(Exception):
        pass

    class BotoCoreError(Exception):
        pass


DEFAULT_CONFIG_RULE = "automation-iam-wildcard-action-policy"
DEFAULT_SSM_DOCUMENT = "automation-iam-wildcard-action-policy"
SSM_TERMINAL_STATES = {"Success", "Failed", "Cancelled", "TimedOut"}
TAGS_OF_INTEREST = (
    "WildcardCategory",
    "WildcardServices",
    "AttachedTo",
    "LastAccessedServices",
    "SuggestedFix",
    "SuggestDate",
    "LastEvaluated",
    "PreviousVersion",
    "NeedsManualReview",
    "FlapLastDetected",
    "CrwdRemediatorExempt",
    "CrwdRemediatorExemptReason",
    "CrwdRemediatorExemptExpiry",
)


# ---------- session / client helpers ----------

def _session(profile: str | None, region: str | None):
    if boto3 is None:
        raise RuntimeError("boto3 is not installed; install requirements.txt to run AWS commands")
    kwargs: dict[str, Any] = {}
    if profile:
        kwargs["profile_name"] = profile
    if region:
        kwargs["region_name"] = region
    return boto3.session.Session(**kwargs)


def _client(sess, name: str):
    return sess.client(name, config=BotoConfig(retries={"max_attempts": 10, "mode": "standard"}))


# ---------- Step 3: start SSM full-analysis ----------

def get_noncompliant_policies(config_client, rule_name: str) -> list[dict[str, str]]:
    """Step 2 equivalent: return every NON_COMPLIANT evaluation result."""
    paginator = config_client.get_paginator("get_compliance_details_by_config_rule")
    results: list[dict[str, str]] = []
    for page in paginator.paginate(ConfigRuleName=rule_name, ComplianceTypes=["NON_COMPLIANT"]):
        for r in page.get("EvaluationResults", []):
            rid = r["EvaluationResultIdentifier"]["EvaluationResultQualifier"]["ResourceId"]
            results.append({"resource_id": rid, "annotation": r.get("Annotation", "")})
    return results


def start_full_analysis(
    ssm_client, document: str, role_arn: str, resource_ids: list[str]
) -> list[dict[str, str]]:
    started: list[dict[str, str]] = []
    for pid in resource_ids:
        try:
            resp = ssm_client.start_automation_execution(
                DocumentName=document,
                Parameters={
                    "ResourceId": [pid],
                    "AutomationAssumeRole": [role_arn],
                    "Action": ["full-analysis"],
                },
            )
            started.append({"policy_id": pid, "execution_id": resp["AutomationExecutionId"]})
            print(f"policy={pid}  exec={resp['AutomationExecutionId']}")
        except ClientError as e:
            print(f"policy={pid}  ERROR: {e.response['Error']['Message']}", file=sys.stderr)
    return started


# ---------- Step 4: wait for executions ----------

def wait_for_executions(
    ssm_client, executions: list[dict[str, str]], poll_s: int = 15, timeout_s: int = 900
) -> dict[str, dict[str, Any]]:
    by_exec = {e["execution_id"]: dict(e, status="Pending") for e in executions}
    deadline = time.monotonic() + timeout_s
    while True:
        pending = [eid for eid, e in by_exec.items() if e["status"] not in SSM_TERMINAL_STATES]
        if not pending:
            break
        if time.monotonic() > deadline:
            for eid in pending:
                by_exec[eid]["status"] = "Timeout"
                by_exec[eid]["failure_reason"] = f"local poll exceeded {timeout_s}s"
            break
        for eid in pending:
            try:
                resp = ssm_client.get_automation_execution(AutomationExecutionId=eid)
                ex = resp["AutomationExecution"]
                status = ex.get("AutomationExecutionStatus", "Pending")
                by_exec[eid]["status"] = status
                start = ex.get("ExecutionStartTime")
                end = ex.get("ExecutionEndTime")
                if start and end:
                    by_exec[eid]["duration_s"] = int((end - start).total_seconds())
                if status == "Failed":
                    by_exec[eid]["failure_reason"] = _collect_failure_reason(ssm_client, eid)
                if status in SSM_TERMINAL_STATES:
                    by_exec[eid]["outputs"] = ex.get("Outputs", {})
            except ClientError as e:
                by_exec[eid]["status"] = "Failed"
                by_exec[eid]["failure_reason"] = e.response["Error"]["Message"]
        terminal = sum(1 for e in by_exec.values() if e["status"] in SSM_TERMINAL_STATES)
        print(f"  [{terminal}/{len(by_exec)}] terminal", file=sys.stderr)
        if any(e["status"] not in SSM_TERMINAL_STATES for e in by_exec.values()):
            time.sleep(poll_s)
    for eid, e in by_exec.items():
        print(f"{eid}  {e['status']}")
    return by_exec


def _collect_failure_reason(ssm_client, exec_id: str) -> str:
    try:
        resp = ssm_client.describe_automation_step_executions(AutomationExecutionId=exec_id)
        failed = [s for s in resp.get("StepExecutions", []) if s.get("StepStatus") == "Failed"]
        if failed:
            return f"{failed[0].get('StepName', '?')}: {failed[0].get('FailureMessage', '?')}"
    except ClientError:
        pass
    return "unknown failure"


# ---------- Step 5+6: scan fleet tags ----------

def scan_fleet_tags(iam_client, max_workers: int = 20) -> list[dict[str, Any]]:
    policies: list[dict[str, Any]] = []
    paginator = iam_client.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for p in page.get("Policies", []):
            policies.append(
                {"policy_arn": p["Arn"], "policy_name": p["PolicyName"], "policy_id": p["PolicyId"]}
            )

    print(f"scanning {len(policies)} customer-managed policies...", file=sys.stderr)
    out: list[dict[str, Any]] = []

    def fetch(entry: dict[str, Any]) -> dict[str, Any] | None:
        try:
            resp = iam_client.list_policy_tags(PolicyArn=entry["policy_arn"])
        except (ClientError, BotoCoreError):
            return None
        tagmap = {t["Key"]: t["Value"] for t in resp.get("Tags", [])}
        if not any(k in tagmap for k in ("WildcardCategory", "CrwdRemediatorExempt")):
            return None
        entry = dict(entry)
        for key in TAGS_OF_INTEREST:
            entry[key] = tagmap.get(key, "")
        return entry

    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        for result in pool.map(fetch, policies):
            done += 1
            if done % 50 == 0:
                print(f"  scanned {done}/{len(policies)}", file=sys.stderr)
            if result is not None:
                out.append(result)
    print(f"  done: {len(out)} matched of {len(policies)}", file=sys.stderr)
    return out


# ---------- state assembly ----------

def build_state(
    *,
    rule_name: str,
    noncompliant: list[dict[str, str]],
    fleet: list[dict[str, Any]],
    executions: dict[str, dict[str, Any]] | None,
    account_id: str,
    region: str,
) -> dict[str, Any]:
    analyzed = [p for p in fleet if p.get("WildcardCategory")]
    exempt = [p for p in fleet if p.get("CrwdRemediatorExempt", "").lower() == "true"]
    flapping = [p for p in fleet if p.get("FlapLastDetected")]

    by_category: dict[str, int] = {}
    for p in analyzed:
        cat = p["WildcardCategory"] or "Unknown"
        by_category[cat] = by_category.get(cat, 0) + 1

    services: dict[str, dict[str, int]] = {}
    for p in analyzed:
        cat = p["WildcardCategory"]
        fix = _parse_suggested_fix(p.get("SuggestedFix", ""))
        for svc in _split_plus(p.get("WildcardServices", "")):
            info = services.setdefault(svc, {"total": 0, "ready": 0, "review": 0})
            info["total"] += 1
            svc_fix = fix.get(svc, [])
            if cat == "Simple" and svc_fix and svc_fix != ["no-data"]:
                info["ready"] += 1
            else:
                info["review"] += 1

    analyzed_ids = {p["policy_id"] for p in analyzed}
    pending = [n for n in noncompliant if n["resource_id"] not in analyzed_ids]

    unused: list[dict[str, Any]] = []
    for p in analyzed:
        ws = set(_split_plus(p.get("WildcardServices", "")))
        las = set(_split_plus(p.get("LastAccessedServices", "")))
        diff = sorted(ws - las - {""})
        if diff and las:
            unused.append({**p, "_unused_wildcards": diff})

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "config_rule": rule_name,
        "account_id": account_id,
        "region": region,
        "totals": {
            "noncompliant": len(noncompliant),
            "analyzed": len(analyzed),
            "pending_analysis": len(pending),
            "exempt": len(exempt),
            "flapping": len(flapping),
            **{f"category_{k.lower()}": v for k, v in by_category.items()},
        },
        "by_category": by_category,
        "services": services,
        "analyzed": analyzed,
        "pending": pending,
        "exempt": exempt,
        "flapping": flapping,
        "unused": unused,
        "executions": executions or {},
    }


def _split_plus(value: str) -> list[str]:
    return [v for v in (value or "").split("+") if v]


def _parse_suggested_fix(value: str) -> dict[str, list[str]]:
    """Parse `svc1=act1+act2/svc2=act3` into {svc: [actions]}.

    `no-data` is preserved verbatim so renderers can distinguish absence
    from an empty list.
    """
    parsed: dict[str, list[str]] = {}
    if not value:
        return parsed
    for chunk in value.split("/"):
        if "=" not in chunk:
            continue
        svc, acts = chunk.split("=", 1)
        svc = svc.strip()
        if not svc:
            continue
        if acts == "no-data":
            parsed[svc] = ["no-data"]
        else:
            parsed[svc] = [a for a in acts.split("+") if a]
    return parsed


# ---------- HTML renderer ----------

_CSS = """
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f1117; color: #e1e4e8; padding: 24px; }
h1 { font-size: 24px; font-weight: 600; margin-bottom: 4px; color: #fff; }
.subtitle { color: #8b949e; font-size: 14px; margin-bottom: 24px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 20px; }
.card .label { font-size: 12px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
.card .value { font-size: 32px; font-weight: 700; margin-top: 4px; }
.simple { color: #3fb950; }
.moderate { color: #d29922; }
.complex { color: #f85149; }
.ready { color: #3fb950; }
.review { color: #d29922; }
.muted { color: #8b949e; }
h2 { font-size: 18px; margin: 32px 0 16px; color: #fff; border-bottom: 1px solid #30363d; padding-bottom: 8px; }
table { width: 100%; border-collapse: collapse; background: #161b22; border-radius: 8px; overflow: hidden; margin-bottom: 24px; }
th { background: #1c2128; text-align: left; padding: 12px 16px; font-size: 12px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
td { padding: 12px 16px; border-top: 1px solid #21262d; font-size: 14px; vertical-align: top; }
tr:hover { background: #1c2128; }
code, .mono { font-family: 'SF Mono', 'Fira Code', Consolas, monospace; font-size: 12px; }
.tag { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 500; margin: 2px; }
.tag-simple { background: #0d3321; color: #3fb950; }
.tag-moderate { background: #3d2e00; color: #d29922; }
.tag-complex { background: #3d1214; color: #f85149; }
.tag-exempt { background: #1c2128; color: #8b949e; border: 1px solid #30363d; }
.tag-ready { background: #0d3321; color: #3fb950; }
.tag-nodata { background: #1c2128; color: #8b949e; }
.tag-status-success { background: #0d3321; color: #3fb950; }
.tag-status-failed { background: #3d1214; color: #f85149; }
.tag-status-pending { background: #1c2128; color: #d29922; }
.action-item { display: inline-block; background: #1c2128; padding: 2px 8px; border-radius: 4px; margin: 2px; border: 1px solid #30363d; font-family: 'SF Mono', 'Fira Code', monospace; font-size: 11px; color: #c9d1d9; }
.svc-section { margin-bottom: 8px; }
.svc-header { font-weight: 600; color: #58a6ff; font-size: 13px; margin-bottom: 4px; }
.meta { color: #8b949e; font-size: 12px; }
.section-empty { color: #8b949e; font-style: italic; padding: 16px; background: #161b22; border: 1px dashed #30363d; border-radius: 8px; }
"""


_CATEGORY_ORDER = ["Complex", "Moderate", "Simple", "Exempt", "Unknown"]


def render_html(state: dict[str, Any]) -> str:
    parts: list[str] = []
    parts.append("<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>")
    parts.append("<title>IAM Wildcard Policy Dashboard</title>")
    parts.append(f"<style>{_CSS}</style></head><body>")
    parts.append("<h1>IAM Wildcard Policy Dashboard</h1>")
    parts.append(
        "<p class='subtitle'>Generated {gen} from account {acc} ({region}) &middot; Config rule: <code>{rule}</code></p>".format(
            gen=html.escape(state["generated_at"]),
            acc=html.escape(state.get("account_id", "unknown")),
            region=html.escape(state.get("region", "unknown")),
            rule=html.escape(state["config_rule"]),
        )
    )

    parts.append(_render_summary(state))
    parts.append(_render_executions(state))
    parts.append(_render_service_summary(state))
    parts.append(_render_policy_details(state))
    parts.append(_render_unused_wildcards(state))
    parts.append(_render_exempt(state))
    parts.append(_render_flapping(state))

    parts.append("</body></html>")
    return "".join(parts)


def _render_summary(state: dict[str, Any]) -> str:
    t = state["totals"]
    cat = state["by_category"]
    cards = [
        ("Non-compliant in Config", str(t["noncompliant"]), ""),
        ("Analyzed", str(t["analyzed"]), ""),
        ("Pending analysis", str(t["pending_analysis"]), "moderate" if t["pending_analysis"] else ""),
        ("Simple", str(cat.get("Simple", 0)), "simple"),
        ("Moderate", str(cat.get("Moderate", 0)), "moderate"),
        ("Complex", str(cat.get("Complex", 0)), "complex"),
        ("Exempt", str(t["exempt"]), "muted"),
        ("Flapping", str(t["flapping"]), "moderate" if t["flapping"] else "muted"),
    ]
    chunks = ["<div class='grid'>"]
    for label, value, css in cards:
        chunks.append(
            "<div class='card'><div class='label'>{l}</div><div class='value {c}'>{v}</div></div>".format(
                l=html.escape(label), v=html.escape(value), c=css
            )
        )
    chunks.append("</div>")
    return "".join(chunks)


def _render_executions(state: dict[str, Any]) -> str:
    executions = state.get("executions") or {}
    if not executions:
        return ""
    rows = []
    for eid, e in sorted(executions.items()):
        status = e.get("status", "Pending")
        status_class = (
            "tag-status-success"
            if status == "Success"
            else "tag-status-failed"
            if status in ("Failed", "Timeout", "Cancelled", "TimedOut")
            else "tag-status-pending"
        )
        rows.append(
            "<tr><td class='mono'>{pid}</td><td class='mono'>{eid}</td>"
            "<td><span class='tag {cls}'>{st}</span></td>"
            "<td>{dur}</td><td class='meta'>{reason}</td></tr>".format(
                pid=html.escape(e.get("policy_id", "")),
                eid=html.escape(eid),
                cls=status_class,
                st=html.escape(status),
                dur=html.escape(f"{e['duration_s']}s") if e.get("duration_s") is not None else "",
                reason=html.escape(e.get("failure_reason", "")),
            )
        )
    return (
        "<h2>This run &mdash; SSM full-analysis executions</h2>"
        "<table><tr><th>Policy</th><th>Execution ID</th><th>Status</th>"
        "<th>Duration</th><th>Failure reason</th></tr>"
        + "".join(rows)
        + "</table>"
    )


def _render_service_summary(state: dict[str, Any]) -> str:
    services = state["services"]
    if not services:
        return "<h2>Service wildcard summary</h2><p class='section-empty'>No analyzed policies yet &mdash; run Step 3 first.</p>"
    rows = []
    for svc in sorted(services):
        info = services[svc]
        rows.append(
            "<tr><td><code>{s}:*</code></td><td>{t}</td>"
            "<td class='ready'>{r}</td><td class='review'>{rv}</td></tr>".format(
                s=html.escape(svc), t=info["total"], r=info["ready"], rv=info["review"]
            )
        )
    return (
        "<h2>Service wildcard summary</h2>"
        "<table><tr><th>Service</th><th>Policies affected</th>"
        "<th>Ready to scope <span class='meta'>(Simple + SuggestedFix)</span></th>"
        "<th>Needs review</th></tr>" + "".join(rows) + "</table>"
    )


def _render_policy_details(state: dict[str, Any]) -> str:
    analyzed = list(state["analyzed"])
    if not analyzed:
        return "<h2>Policy details</h2><p class='section-empty'>No analyzed policies yet.</p>"
    analyzed.sort(key=lambda p: (_CATEGORY_ORDER.index(p.get("WildcardCategory", "Unknown")) if p.get("WildcardCategory", "Unknown") in _CATEGORY_ORDER else 99, p.get("policy_name", "")))

    rows = []
    for p in analyzed:
        cat = p.get("WildcardCategory") or "Unknown"
        cat_class = f"tag-{cat.lower()}" if cat.lower() in ("simple", "moderate", "complex") else "tag-exempt"
        attached = p.get("AttachedTo", "unattached") or "unattached"
        last_accessed = p.get("LastAccessedServices", "")
        last_html = ""
        if last_accessed:
            tags = "".join(f"<span class='action-item'>{html.escape(s)}</span>" for s in _split_plus(last_accessed))
            last_html = f"<br><span class='meta'>Last accessed:</span> {tags}"
        fix_parts = _parse_suggested_fix(p.get("SuggestedFix", ""))
        fix_html_chunks = []
        for svc in sorted(_split_plus(p.get("WildcardServices", ""))):
            actions = fix_parts.get(svc, [])
            fix_html_chunks.append(f"<div class='svc-section'><div class='svc-header'>{html.escape(svc)}:*</div>")
            if actions == ["no-data"]:
                fix_html_chunks.append("<span class='tag tag-nodata'>no CloudTrail data</span>")
            elif actions:
                for a in actions:
                    fix_html_chunks.append(f"<span class='action-item'>{html.escape(svc)}:{html.escape(a)}</span>")
            else:
                fix_html_chunks.append("<span class='meta'>(no suggestion stored)</span>")
            fix_html_chunks.append("</div>")
        needs_review = p.get("NeedsManualReview", "").lower() == "true"
        if needs_review:
            fix_html_chunks.append("<span class='tag tag-moderate'>NeedsManualReview</span>")
        last_eval = p.get("LastEvaluated") or p.get("SuggestDate") or ""
        rows.append(
            "<tr><td><strong>{name}</strong><br><span class='meta mono'>{arn}</span>"
            "{le}</td>"
            "<td><span class='tag {cc}'>{cat}</span></td>"
            "<td>{att}{la}</td>"
            "<td>{fix}</td></tr>".format(
                name=html.escape(p.get("policy_name", "")),
                arn=html.escape(p.get("policy_arn", "")),
                le=f"<br><span class='meta'>Last evaluated: {html.escape(last_eval)}</span>" if last_eval else "",
                cc=cat_class,
                cat=html.escape(cat),
                att=html.escape(attached),
                la=last_html,
                fix="".join(fix_html_chunks),
            )
        )
    truncation = (
        "<p class='meta'>Suggested fix is read from the <code>SuggestedFix</code> IAM tag, "
        "truncated at 256 chars. Configure <code>report_s3_bucket</code> on the module for full per-service detail.</p>"
    )
    return (
        "<h2>Policy details</h2>" + truncation +
        "<table><tr><th>Policy</th><th>Category</th><th>Attached to</th><th>Suggested fix</th></tr>"
        + "".join(rows) + "</table>"
    )


def _render_unused_wildcards(state: dict[str, Any]) -> str:
    unused = state.get("unused", [])
    if not unused:
        return "<h2>Unused wildcards</h2><p class='section-empty'>No policies with wildcards outside their last-accessed services &mdash; or no role had CloudTrail activity yet.</p>"
    rows = []
    for p in sorted(unused, key=lambda x: x.get("policy_name", "")):
        diff_tags = "".join(f"<span class='action-item'>{html.escape(s)}</span>" for s in p["_unused_wildcards"])
        rows.append(
            "<tr><td><strong>{name}</strong><br><span class='meta mono'>{arn}</span></td>"
            "<td>{diff}</td><td class='meta'>Last accessed: {la}</td></tr>".format(
                name=html.escape(p.get("policy_name", "")),
                arn=html.escape(p.get("policy_arn", "")),
                diff=diff_tags,
                la=html.escape(p.get("LastAccessedServices", "")),
            )
        )
    return (
        "<h2>Unused wildcards <span class='meta'>(safe-to-remove candidates)</span></h2>"
        "<table><tr><th>Policy</th><th>Services never accessed</th><th>Context</th></tr>"
        + "".join(rows) + "</table>"
    )


def _render_exempt(state: dict[str, Any]) -> str:
    exempt = state.get("exempt", [])
    if not exempt:
        return ""
    rows = []
    for p in sorted(exempt, key=lambda x: x.get("policy_name", "")):
        rows.append(
            "<tr><td><strong>{name}</strong><br><span class='meta mono'>{arn}</span></td>"
            "<td class='meta'>{reason}</td><td class='meta'>{exp}</td></tr>".format(
                name=html.escape(p.get("policy_name", "")),
                arn=html.escape(p.get("policy_arn", "")),
                reason=html.escape(p.get("CrwdRemediatorExemptReason", "")) or "&mdash;",
                exp=html.escape(p.get("CrwdRemediatorExemptExpiry", "")) or "&mdash;",
            )
        )
    return (
        "<h2>Exempt policies</h2>"
        "<table><tr><th>Policy</th><th>Reason</th><th>Expiry</th></tr>"
        + "".join(rows) + "</table>"
    )


def _render_flapping(state: dict[str, Any]) -> str:
    flapping = state.get("flapping", [])
    if not flapping:
        return ""
    rows = []
    for p in sorted(flapping, key=lambda x: x.get("FlapLastDetected", ""), reverse=True):
        rows.append(
            "<tr><td class='meta mono'>{ts}</td>"
            "<td><strong>{name}</strong><br><span class='meta mono'>{arn}</span></td></tr>".format(
                ts=html.escape(p.get("FlapLastDetected", "")),
                name=html.escape(p.get("policy_name", "")),
                arn=html.escape(p.get("policy_arn", "")),
            )
        )
    return (
        "<h2>Flapping policies</h2>"
        "<table><tr><th>Last detected</th><th>Policy</th></tr>"
        + "".join(rows) + "</table>"
    )


# ---------- subcommands ----------

def cmd_start(args: argparse.Namespace) -> int:
    sess = _session(args.profile, args.region)
    cfg = _client(sess, "config")
    ssm = _client(sess, "ssm")
    nc = get_noncompliant_policies(cfg, args.config_rule)
    if args.limit:
        nc = nc[: args.limit]
    if not nc:
        print("No non-compliant policies found.", file=sys.stderr)
        return 0
    started = start_full_analysis(ssm, args.ssm_document, args.assume_role_arn, [n["resource_id"] for n in nc])
    return 0 if started else 1


def cmd_watch(args: argparse.Namespace) -> int:
    sess = _session(args.profile, args.region)
    ssm = _client(sess, "ssm")
    exec_ids = list(args.execution_ids)
    if not exec_ids and not sys.stdin.isatty():
        for line in sys.stdin:
            for tok in line.split():
                if tok.startswith("exec="):
                    exec_ids.append(tok.split("=", 1)[1])
    if not exec_ids:
        print("usage: watch <exec-id> [exec-id ...]  (or pipe 'exec=ID' lines via stdin)", file=sys.stderr)
        return 2
    executions = [{"policy_id": "", "execution_id": eid} for eid in exec_ids]
    wait_for_executions(ssm, executions, poll_s=args.poll_seconds, timeout_s=args.timeout_seconds)
    return 0


def cmd_collect(args: argparse.Namespace) -> int:
    sess = _session(args.profile, args.region)
    cfg = _client(sess, "config")
    iam = _client(sess, "iam")
    sts = _client(sess, "sts")
    ident = sts.get_caller_identity()
    noncompliant = get_noncompliant_policies(cfg, args.config_rule)
    fleet = scan_fleet_tags(iam, max_workers=args.workers)
    state = build_state(
        rule_name=args.config_rule,
        noncompliant=noncompliant,
        fleet=fleet,
        executions=None,
        account_id=ident.get("Account", "unknown"),
        region=sess.region_name or "unknown",
    )
    _emit(state, args)
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    sess = _session(args.profile, args.region)
    cfg = _client(sess, "config")
    ssm = _client(sess, "ssm")
    iam = _client(sess, "iam")
    sts = _client(sess, "sts")
    ident = sts.get_caller_identity()

    noncompliant = get_noncompliant_policies(cfg, args.config_rule)
    target = noncompliant[: args.limit] if args.limit else noncompliant
    executions: dict[str, dict[str, Any]] = {}
    if target:
        started = start_full_analysis(
            ssm, args.ssm_document, args.assume_role_arn, [n["resource_id"] for n in target]
        )
        if started:
            executions = wait_for_executions(ssm, started, poll_s=args.poll_seconds, timeout_s=args.timeout_seconds)
    else:
        print("No NON_COMPLIANT resources returned by Config; skipping Step 3.", file=sys.stderr)

    fleet = scan_fleet_tags(iam, max_workers=args.workers)
    state = build_state(
        rule_name=args.config_rule,
        noncompliant=noncompliant,
        fleet=fleet,
        executions=executions,
        account_id=ident.get("Account", "unknown"),
        region=sess.region_name or "unknown",
    )
    _emit(state, args)
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    with open(args.fixture) as f:
        state = json.load(f)
    _emit(state, args)
    return 0


def _emit(state: dict[str, Any], args: argparse.Namespace) -> None:
    if args.state_json:
        with open(args.state_json, "w") as f:
            json.dump(state, f, indent=2, default=str)
        print(f"State JSON written to {args.state_json}")
    html_out = render_html(state)
    with open(args.output, "w") as f:
        f.write(html_out)
    print(f"Dashboard written to {args.output}")


# ---------- argparse ----------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--region", help="AWS region (default: session default)")

    sub = p.add_subparsers(dest="cmd", required=True)

    def _aws_opts(sp):
        sp.add_argument("--config-rule", default=DEFAULT_CONFIG_RULE)
        sp.add_argument("--ssm-document", default=DEFAULT_SSM_DOCUMENT)
        sp.add_argument("--assume-role-arn", help="SSM AutomationAssumeRole ARN")

    def _output_opts(sp):
        sp.add_argument("--output", default="dashboard.html", help="HTML output path")
        sp.add_argument("--state-json", help="Optional path to dump the raw state JSON")

    def _wait_opts(sp):
        sp.add_argument("--poll-seconds", type=int, default=15)
        sp.add_argument("--timeout-seconds", type=int, default=900)

    start = sub.add_parser("start", help="Step 3: start SSM full-analysis on top-N NON_COMPLIANT")
    _aws_opts(start)
    start.add_argument("--limit", type=int, default=5)
    start.set_defaults(func=cmd_start)

    watch = sub.add_parser("watch", help="Step 4: poll SSM executions until terminal")
    watch.add_argument("execution_ids", nargs="*")
    _wait_opts(watch)
    watch.set_defaults(func=cmd_watch)

    collect = sub.add_parser("collect", help="Steps 5+6: scan tags and render dashboard")
    _aws_opts(collect)
    _output_opts(collect)
    collect.add_argument("--workers", type=int, default=20)
    collect.set_defaults(func=cmd_collect)

    run = sub.add_parser("run", help="End-to-end: Steps 3->4->5->6 + render")
    _aws_opts(run)
    _output_opts(run)
    _wait_opts(run)
    run.add_argument("--limit", type=int, default=5)
    run.add_argument("--workers", type=int, default=20)
    run.set_defaults(func=cmd_run)

    render = sub.add_parser("render", help="Render HTML from a state JSON fixture (offline)")
    render.add_argument("--fixture", required=True, help="Path to state JSON")
    _output_opts(render)
    render.set_defaults(func=cmd_render)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ClientError as e:
        print(f"AWS error: {e.response['Error'].get('Message', str(e))}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
