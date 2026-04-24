#!/usr/bin/env python3
"""Generate a standalone HTML dashboard from S3 wildcard analysis reports."""

import boto3
import json
import sys
from datetime import datetime

BUCKET = sys.argv[1] if len(sys.argv) > 1 else "crwd-test-reports-934791682619"
PREFIX = "iam-wildcard-reports/"
OUTPUT = "dashboard.html"

s3 = boto3.client("s3")

# Collect all reports (latest per policy)
reports = {}
paginator = s3.get_paginator("list_objects_v2")
for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX):
    for obj in page.get("Contents", []):
        key = obj["Key"]
        resp = s3.get_object(Bucket=BUCKET, Key=key)
        data = json.loads(resp["Body"].read())
        policy_name = data.get("policy_name", "unknown")
        # Keep latest report per policy
        if policy_name not in reports or data.get("assessed_date", "") > reports[policy_name].get("assessed_date", ""):
            reports[policy_name] = data

if not reports:
    print(f"No reports found in s3://{BUCKET}/{PREFIX}")
    sys.exit(1)

# Compute summary stats
total = len(reports)
by_category = {}
all_services = {}
threshold_met = 0
threshold_not = 0

for name, r in reports.items():
    cat = r.get("category", "Unknown")
    by_category[cat] = by_category.get(cat, 0) + 1
    for svc, info in r.get("suggestions", {}).items():
        if svc not in all_services:
            all_services[svc] = {"total": 0, "meets_threshold": 0, "no_data": 0}
        all_services[svc]["total"] += 1
        if info.get("meets_threshold"):
            all_services[svc]["meets_threshold"] += 1
        if info.get("action_count", 0) == 0:
            all_services[svc]["no_data"] += 1

generated = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

# Generate HTML
html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>IAM Wildcard Policy Analysis</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f1117; color: #e1e4e8; padding: 24px; }}
  h1 {{ font-size: 24px; font-weight: 600; margin-bottom: 4px; color: #fff; }}
  .subtitle {{ color: #8b949e; font-size: 14px; margin-bottom: 24px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }}
  .card {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 20px; }}
  .card .label {{ font-size: 12px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }}
  .card .value {{ font-size: 32px; font-weight: 700; margin-top: 4px; }}
  .simple {{ color: #3fb950; }}
  .moderate {{ color: #d29922; }}
  .complex {{ color: #f85149; }}
  .ready {{ color: #3fb950; }}
  .review {{ color: #d29922; }}
  h2 {{ font-size: 18px; margin: 32px 0 16px; color: #fff; border-bottom: 1px solid #30363d; padding-bottom: 8px; }}
  table {{ width: 100%; border-collapse: collapse; background: #161b22; border-radius: 8px; overflow: hidden; }}
  th {{ background: #1c2128; text-align: left; padding: 12px 16px; font-size: 12px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }}
  td {{ padding: 12px 16px; border-top: 1px solid #21262d; font-size: 14px; vertical-align: top; }}
  tr:hover {{ background: #1c2128; }}
  .tag {{ display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 500; margin: 2px; }}
  .tag-simple {{ background: #0d3321; color: #3fb950; }}
  .tag-moderate {{ background: #3d2e00; color: #d29922; }}
  .tag-complex {{ background: #3d1214; color: #f85149; }}
  .tag-ready {{ background: #0d3321; color: #3fb950; }}
  .tag-nodata {{ background: #1c2128; color: #8b949e; }}
  .actions {{ font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px; color: #c9d1d9; line-height: 1.8; }}
  .action-item {{ display: inline-block; background: #1c2128; padding: 2px 8px; border-radius: 4px; margin: 2px; border: 1px solid #30363d; }}
  .svc-section {{ margin-bottom: 12px; }}
  .svc-header {{ font-weight: 600; color: #58a6ff; font-size: 13px; margin-bottom: 4px; }}
  .meta {{ color: #8b949e; font-size: 12px; }}
</style>
</head>
<body>
<h1>IAM Wildcard Policy Analysis Dashboard</h1>
<p class="subtitle">Generated {generated} from s3://{BUCKET}/{PREFIX}</p>

<div class="grid">
  <div class="card">
    <div class="label">Total Policies Analyzed</div>
    <div class="value">{total}</div>
  </div>
  <div class="card">
    <div class="label">Simple</div>
    <div class="value simple">{by_category.get('Simple', 0)}</div>
  </div>
  <div class="card">
    <div class="label">Moderate</div>
    <div class="value moderate">{by_category.get('Moderate', 0)}</div>
  </div>
  <div class="card">
    <div class="label">Complex</div>
    <div class="value complex">{by_category.get('Complex', 0)}</div>
  </div>
</div>

<h2>Service Wildcard Summary</h2>
<table>
<tr><th>Service</th><th>Policies Affected</th><th>Ready to Scope</th><th>Needs Review</th></tr>
"""

for svc in sorted(all_services.keys()):
    info = all_services[svc]
    html += f"<tr><td><code>{svc}:*</code></td><td>{info['total']}</td>"
    html += f"<td class='ready'>{info['meets_threshold']}</td>"
    html += f"<td class='review'>{info['total'] - info['meets_threshold']}</td></tr>\n"

html += """</table>

<h2>Policy Details</h2>
<table>
<tr><th>Policy</th><th>Category</th><th>Attached To</th><th>Suggestions</th></tr>
"""

for name in sorted(reports.keys()):
    r = reports[name]
    cat = r.get("category", "Unknown")
    cat_class = cat.lower()
    attached = r.get("attached_to", "unattached")
    last_accessed = r.get("last_accessed_services", [])

    suggestions_html = ""
    for svc, info in r.get("suggestions", {}).items():
        replacements = info.get("suggested_replacements", [])
        meets = info.get("meets_threshold", False)
        count = info.get("action_count", 0)

        suggestions_html += f'<div class="svc-section"><div class="svc-header">{svc}:* '
        if meets:
            suggestions_html += f'<span class="tag tag-ready">{count} actions found</span>'
        elif count > 0:
            suggestions_html += f'<span class="tag tag-moderate">{count} actions (below threshold)</span>'
        else:
            suggestions_html += '<span class="tag tag-nodata">no data</span>'
        suggestions_html += '</div><div class="actions">'

        if replacements:
            for action in sorted(replacements):
                suggestions_html += f'<span class="action-item">{action}</span>'
        else:
            suggestions_html += '<span class="meta">No CloudTrail activity found for this service</span>'
        suggestions_html += '</div></div>'

    last_accessed_html = ""
    if last_accessed:
        last_accessed_html = f'<br><span class="meta">Last accessed: {", ".join(last_accessed)}</span>'

    html += f"""<tr>
<td><strong>{name}</strong><br><span class="meta">{r.get('policy_arn', '')}</span></td>
<td><span class="tag tag-{cat_class}">{cat}</span></td>
<td>{attached}{last_accessed_html}</td>
<td>{suggestions_html}</td>
</tr>
"""

html += f"""</table>
<p class="subtitle" style="margin-top: 32px;">Source: s3://{BUCKET}/{PREFIX} | {total} policies | {len(all_services)} wildcard services</p>
</body></html>"""

with open(OUTPUT, "w") as f:
    f.write(html)

print(f"Dashboard written to {OUTPUT}")
print(f"  {total} policies, {len(all_services)} wildcard services")
