# Close IAM overpermissive-policy coverage gaps: full-wildcard detection and inline-policy evaluation

## Problem Statement

The cloud security team is receiving a high volume of CrowdStrike alerts in our GovCloud environment flagging overly permissive IAM policies — specifically the `Action: "*"` (full wildcard) pattern — across several AWS accounts. The alert volume is concentrated in two coverage gaps:

1. **Inline policies on roles, users, and groups.** A meaningful share — likely the majority — of the offending policies are inline policies created via `aws iam put-role-policy`, the AWS Console's "Add inline policy" flow, or boto3 calls. Engineers reach for inline policies because they bypass the central deployment pipeline that the security team does not have authority to modify. The existing `iam-wildcard-action-policy` module's Config rule is scoped to the `AWS::IAM::Policy` resource type, which represents customer-managed policies only. Inline policies are recorded as fields inside the principal's configurationItem (`rolePolicyList`, `userPolicyList`, `groupPolicyList`) and never surface to a Config rule scoped to `AWS::IAM::Policy`.

2. **Customer-managed policies with `Action: "*"`.** The existing module's Lambda evaluator deliberately excludes the bare `Action: "*"` pattern (per the existing handler's filter logic) because AWS publishes a managed Config rule (`IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS`) intended to fill that role under repo Rule 10 (prefer AWS managed Config rules). That managed rule has not been deployed in this environment, so the customer-managed full-wildcard quadrant is currently uncovered.

Engineers continue to introduce new findings daily through the same off-pipeline paths, so a one-time cleanup is insufficient — the controls need to be detective and remediative on an ongoing basis. Operators triaging the existing findings have no unified view across CMP-vs-inline sources, which slows down prioritization and hides cross-source patterns (e.g., a single role with both an inline `Action: "*"` and an attached customer-managed `s3:*`).

## Solution

Ship two new sibling modules and extend the existing dashboard so the four-quadrant coverage matrix (CMP vs. inline × `Action: "*"` vs. `<service>:*`) is fully addressed, with a single dashboard surface for stakeholders.

The first new module, `iam-overpermissive-inline-policy`, evaluates `AWS::IAM::Role`, `AWS::IAM::User`, and `AWS::IAM::Group` resources and flags any inline policy statement using `Action: "*"` or `<service>:*` wildcards. Detection covers all three principal types; mutating remediation defaults to Role and User only, with Group remediation gated behind an opt-in flag because of fan-out blast radius. Because inline policies have no native version history, an S3 backup bucket is a required deployment input — backups are written before any mutation and serve as the rollback substrate.

The second new module, `iam-policy-no-fullwildcard`, deploys the AWS-managed Config rule `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` with a thin remediation wrapper. It tags policies with severity and routes findings into the dashboard. It deliberately does not auto-scope, since CloudTrail-driven scoping of full wildcards in customer-managed policies is too low-confidence to apply automatically.

The dashboard module (`iam-wildcard-action-policy-dashboard`) is extended to ingest the two new sources alongside its existing input. The output is a single HTML page with a unified, severity-sorted table that uses a `Source` column (CMP vs. Inline) and a `Pattern` column (`Action:*` vs. `<service>:*`), with severity color coding and per-row copy-to-clipboard CLI buttons that pre-fill the right ARN or role-name for the operator to either exempt or remediate that specific finding.

All three modules ship with the repo's standard conservative posture: `automatic_remediation = false` by default (Rule 8), default mode is `analyze` (tag-only, no mutation), two-tier exemption (list-based + tag-based per Rule 11), and dynamic-partition ARN handling so the modules work in commercial and GovCloud partitions. v1 is single-account testing via `terraform apply`; multi-account fan-out is deferred to a later iteration.

## User Stories

### As a cloud security engineer driving the rollout

1. As a cloud security engineer, I want to deploy all three remediator modules from a single Terraform root configuration, so that I can stand up full coverage with one `terraform apply` per account.
2. As a cloud security engineer, I want every new module to default to dry-run (`automatic_remediation = false`) and analyze-only mode, so that day-1 deploys cannot mutate production policies before I have reviewed the findings.
3. As a cloud security engineer, I want the inline module to refuse to deploy if I omit the S3 backup bucket and have selected a mutating mode, so that I cannot accidentally ship a destructive remediator without a rollback substrate.
4. As a cloud security engineer, I want consistent variable names across all three modules (e.g., `name_prefix`, `excluded_resource_ids`, `tags`, `automatic_remediation`), so that I can compose them without learning three different APIs.
5. As a cloud security engineer, I want all three modules to support the existing `CrwdRemediatorExempt` tag schema, so that exemption discipline is uniform across remediators.
6. As a cloud security engineer, I want all three modules to honor the dynamic AWS partition (`data.aws_partition.current.partition`), so that I can deploy the same modules in GovCloud and commercial without per-partition forks.
7. As a cloud security engineer, I want a single dashboard URL that surfaces findings from all three modules, so that I can hand stakeholders one bookmark instead of three.
8. As a cloud security engineer, I want to ramp from `analyze` to mutating modes module-by-module, so that I can isolate operational risk one detection class at a time.

### As an IAM operator triaging findings

9. As an IAM operator, I want findings sorted by severity at the top of the dashboard, so that the highest-impact `Action: "*"` cases surface before lower-impact `<service>:*` ones.
10. As an IAM operator, I want each row to indicate whether it's a customer-managed policy or an inline policy, so that I know which remediation playbook applies before I click into it.
11. As an IAM operator, I want each row to indicate the wildcard pattern (`Action: "*"` vs. `<service>:*`), so that I know whether auto-scoping is even available for that finding.
12. As an IAM operator, I want a copy-to-clipboard button per row that gives me the exact AWS CLI command to exempt that specific finding (with the right ARN or role-name pre-filled), so that I do not have to hand-edit ARNs into a runbook.
13. As an IAM operator, I want a copy-to-clipboard button per row that gives me the exact AWS CLI command to remediate that specific finding, so that I can act on individual findings without context-switching to the runbook.
14. As an IAM operator, I want the dashboard to show me which findings are currently exempt (and the reason), so that I can audit exemption discipline at a glance.
15. As an IAM operator, I want findings tagged as `NeedsManualReview` to be visually distinct from auto-scopable findings, so that I can route them to a human reviewer and deprioritize them in my queue.
16. As an IAM operator, I want flapping policies (those repeatedly re-introducing the wildcard from a source-of-truth) called out in a top-of-page rollup, so that I can route those to the owning team to fix at source.

### As an engineer who created an offending policy

17. As an engineer, I want to learn what wildcard pattern I introduced (and on which principal), so that I can fix it in my source-of-truth before the next remediation cycle.
18. As an engineer, I want to receive a CloudTrail-derived suggestion of the specific actions my role is actually using, so that I can write a least-privilege replacement without guessing.
19. As an engineer, I want to be able to tag my own role with `CrwdRemediatorExempt=true` plus a reason, so that I can pause remediation while I fix the source-of-truth.
20. As an engineer, I want exemption tags to require a non-empty `CrwdRemediatorExemptReason`, so that bare exemptions cannot be applied silently.
21. As an engineer, I want the inline module to back up my original inline policy to S3 before any mutation, so that I have a documented restore path if scoping breaks my workload.
22. As an engineer, I want the rollback command to be discoverable from a tag on my role (the S3 backup key), so that recovery does not require me to know the bucket name.

### As a security stakeholder

23. As a security stakeholder, I want a per-account rollup at the top of the dashboard showing critical (`Action: "*"`) and high (`<service>:*`) counts, so that I can answer "where is our IAM hygiene worst" without scrolling.
24. As a security stakeholder, I want exempt and flapping counts to appear in the rollup, so that I understand how much of the residual finding count is governance vs. unfixed risk.
25. As a security stakeholder, I want the dashboard to be a static HTML file with no JavaScript framework, so that it loads quickly and can be archived as evidence for audits.
26. As a security stakeholder, I want to see findings on `User` and `Group` principals as well as `Role`, so that legacy human-IAM-user grants and shared-group grants are not invisible to the program.

### As a developer extending the system

27. As a developer extending these modules, I want detection logic (the wildcard-pattern matcher) to be a pure, well-tested function, so that I can extend the matcher to new patterns without coupling to AWS Config delivery semantics.
28. As a developer extending these modules, I want a shared CloudTrail action-discovery helper, so that the existing module and the new inline module do not diverge on how they query CloudTrail or apply the `meets_threshold` gate.
29. As a developer extending these modules, I want each module's Terraform-plan tests to enforce ≥5 assertions per Rule 9, so that resource-graph regressions are caught before deploy.
30. As a developer extending these modules, I want the dashboard's renderer to be testable via a golden-file comparison, so that table layout and copy-CLI templating regressions are caught without running a browser.

### As an auditor

31. As an auditor, I want every exemption to be traceable to a reason string and (where automated) an expiry date, so that I can confirm exemption discipline meets policy requirements.
32. As an auditor, I want the S3 backup bucket to retain inline-policy originals indefinitely (or per a documented retention rule), so that any post-incident review has the pre-mutation policy available.
33. As an auditor, I want each finding's last-evaluated timestamp to be discoverable, so that I can confirm the controls are running on a current cadence.

### As an operations team owning rollback

34. As an operations team member, I want the inline module to write the S3 backup key to a tag on the principal at remediation time, so that rollback is a one-line CLI invocation rather than a backup-bucket scan.
35. As an operations team member, I want the inline module's `delete-and-backup` mode to require explicit operator action (not the default), so that destructive remediation cannot fire automatically across multiple accounts overnight.
36. As an operations team member, I want Group remediation to be opt-in via a dedicated flag, so that fan-out blast radius (one delete affecting all group members) requires a deliberate decision per deployment.

### As a stakeholder watching the multi-account rollout

37. As a multi-account stakeholder, I want v1 to deploy cleanly to a single test account before any fan-out work, so that I can validate behavior with low blast radius.
38. As a multi-account stakeholder, I want the modules to be composable in a per-account multi-provider Terraform wrapper later, so that we have a clear path to N-account deployment when v1 testing concludes.

## Implementation Decisions

### Modules to be built or modified

- **`iam-overpermissive-inline-policy`** (new). Custom Lambda Config rule scoped to a single Config rule with `compliance_resource_types = ["AWS::IAM::Role", "AWS::IAM::User", "AWS::IAM::Group"]`. Single Lambda evaluator branches internally on `resourceType` to walk `rolePolicyList`, `userPolicyList`, or `groupPolicyList` and flag any statement whose `Action` is `"*"` or matches `<service>:*`. Pairs with an SSM Automation document supporting four modes: `analyze` (tag-only, default), `backup-only` (write inline doc to S3, no mutation), `scope-and-backup` (S3-backup → CloudTrail-discover → `PutRolePolicy` with scoped action list; refuses on `Action: "*"` and downgrades to `analyze` + `NeedsManualReview` tag), and `delete-and-backup` (S3-backup → `DeleteRolePolicy`/`DeleteUserPolicy`/`DeleteGroupPolicy`). IAM role for the SSM document is partition-dynamic and scoped to the principal-mutation API set plus CloudTrail lookup and S3 backup writes.

- **`iam-policy-no-fullwildcard`** (new). Thin module wrapping the AWS-managed Config rule `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS` with the standard remediation-config wiring. Default `remediation_action` is `tag-and-route` (analyze-equivalent — apply a `WildcardCategory=FullWildcard` tag and surface the finding to the dashboard). No auto-scope mode; full wildcards in customer-managed policies are too risky to auto-rewrite from CloudTrail, so this module's mutating responsibility is limited to deletion (operator-triggered).

- **`iam-wildcard-action-policy-dashboard`** (modified). Existing module is extended to ingest two additional Config-rule data sources (the two new modules' rule names). Renderer is updated to emit a single unified HTML table with columns `Severity`, `Source` (CMP/Inline), `Resource` (showing `policy/<name>` for CMP, `<principal-type>/<name>#<inline-policy-name>` for inline), `Pattern` (`Action:*` or `<service>:*`), and per-row copy-CLI buttons. Severity is pattern-derived: CRIT for `Action: "*"`, HIGH for `<service>:*`. Top-of-page rollup is account-scoped and includes critical, high, exempt, and flapping counts.

### Module interfaces

- **Shared variable surface across all three new/modified modules**: `name_prefix`, `tags`, `automatic_remediation` (default `false`), `excluded_resource_ids`, `tag_based_exemption_enabled` (default `true`), `exemption_tag_key` (default `CrwdRemediatorExempt`), `require_exemption_reason` (default `true`).

- **Inline module additions**: `inline_backup_s3_bucket` (required when any mutating mode is selected — enforced via Terraform precondition; no default), `enable_role_remediation` (default `true`), `enable_user_remediation` (default `true`), `enable_group_remediation` (default `false` — opt-in due to fan-out blast radius), `cloudtrail_lookback_days` (default `90`), `min_actions_threshold` (default `3`), `remediation_action` (one of `analyze`, `backup-only`, `scope-and-backup`, `delete-and-backup`; default `analyze`).

- **Inline module exemption ID format**: composite `<principal-type>/<name>[#<inline-policy-name>]`. The `#<inline-policy-name>` suffix is optional; when omitted, the exemption applies to all inline policies on that principal. Tag-based exemption uses tags on the principal: `CrwdRemediatorExempt=true` (exempt all inline policies on the principal), `CrwdRemediatorExemptInlinePolicies=<csv>` (exempt only the listed inline-policy names on this principal), `CrwdRemediatorExemptReason=<text>` (required when `require_exemption_reason = true`).

- **Inline module pattern-aware remediation**: SSM document branches on the detected pattern. For `Action: "*"` findings, `scope-and-backup` is refused (downgrades to `analyze` and tags `NeedsManualReview=true` with reason `full-wildcard-not-auto-scopable`); `delete-and-backup` is permitted. For `<service>:*` findings, all mutating modes are permitted. The module deliberately does not perform resource-level or condition-level scoping; suggestions are action-list only, mirroring the existing module.

- **Full-wildcard module additions**: `remediation_action` (one of `tag-and-route`, `delete-managed`; default `tag-and-route`), `report_s3_bucket` (optional, mirrors the existing module).

- **Dashboard module additions**: a new `inline_config_rule_name` input (the inline module's rule name), a new `fullwildcard_config_rule_name` input (the full-wildcard module's rule name); both optional so the dashboard can be deployed with any subset of upstream modules. The renderer must gracefully degrade to single-source rendering if the new inputs are empty.

### Architectural decisions captured during design

- **Three modules instead of one extended module.** Inline-policy remediation has fundamentally different IAM API semantics from customer-managed-policy remediation (`PutRolePolicy` overwrite vs. `CreatePolicyVersion` versioned), and no native rollback. Splitting keeps each module's blast radius and rollback story coherent and matches the repo's narrow-remediator convention.

- **Single Config rule per module, multi-resource-type scope.** The inline module uses one Config rule with all three principal resource types in `compliance_resource_types` rather than three separate rules, simplifying compliance aggregation and reducing per-rule resource sprawl.

- **Conservative defaults across the board.** Every module ships with `automatic_remediation = false` and `remediation_action = "analyze"`. Mutating modes exist but require explicit operator selection. This matches the existing module's posture and is documented in feedback memory.

- **Pattern-derived severity.** The dashboard's severity classification (`CRIT` for `Action: "*"`, `HIGH` for `<service>:*`) is hardcoded in the renderer rather than configurable. Operators tune which findings to act on via exemption, not via redefining severity.

- **Action-level scoping only.** Recommended replacements are always action lists; the modules do not propose resource ARNs or condition keys. Rationale: CloudTrail's resource attribution is workload-specific and high-risk to apply automatically, and adding it would compound the blast radius of scoping errors.

- **GovCloud partition support.** All ARNs constructed in module IAM policies use `data.aws_partition.current.partition` so the modules deploy unchanged in `aws-us-gov`. The existing module's pattern is the prior art.

- **Single-account v1 deployment.** No multi-provider wrapper, no StackSet, no conformance pack at v1. Each module is deployed once per account via `terraform apply`. Multi-account fan-out is a separate workstream.

- **Prevention layer is out of scope for this PRD.** SCPs, permission boundaries, and IAM Access Analyzer policy validation are deliberately deferred. Detective and corrective controls ship first; once analyze data reveals which mutation patterns drive the alert volume, the prevention layer is its own design conversation.

## Testing Decisions

### What makes a good test

Tests must verify external behavior — the contracts the modules expose to operators and other modules — not implementation details. For Terraform modules, "external behavior" means the resource graph that `terraform plan` produces given a set of inputs (resource counts, names, scopes, IAM permission shapes, output values), not the internal structure of `locals` or intermediate `data` blocks. For the Lambda evaluator, it means the compliance evaluation produced for a given configurationItem fixture, not the internal pattern-matching loop. For the dashboard, it means the rendered HTML output for a given input dataset, not the templating engine's internal calls.

A test that breaks on a refactor that preserves behavior is a bad test. A test that catches a regression in the contract operators rely on is a good one.

### Modules to be tested

All three new and modified modules require tests, with the following test types:

- **Inline-policy Lambda evaluator (Python).** Unit tests using fixture configurationItem JSON for `AWS::IAM::Role`, `AWS::IAM::User`, and `AWS::IAM::Group` resource types. Coverage cases include: full-wildcard `Action: "*"` matches, service-wildcard `<service>:*` matches, mixed-action statements (some specific, some wildcard), `Effect: Deny` statements (must not flag), `NotAction` inversions (must not flag — out of scope), missing `rolePolicyList`/`userPolicyList`/`groupPolicyList` (NOT_APPLICABLE), URL-encoded vs. plain policy documents, multi-statement policies, policies with `Action` as both string and list, and resources whose `resourceType` is not one of the three covered types.

- **CloudTrail action-discovery helper (Python).** Unit tests using mocked `boto3` responses for `cloudtrail:LookupEvents` and `iam:GetServiceLastAccessedDetails`. Coverage cases include: discovered actions exceed `min_actions_threshold` (returns scoped list, `meets_threshold = true`), discovered actions below threshold (returns list, `meets_threshold = false`), CloudTrail returns no events for the role-service combination (returns empty, `meets_threshold = false`), eventSource mismatches (e.g., `cloudwatch:*` actions logged under `monitoring.amazonaws.com`), and lookback windows at the documented bounds.

- **Pattern classifier (Python).** Pure-function unit tests. Coverage cases: bare `*`, `<service>:*` for various service prefixes, verb-prefix wildcards like `s3:Get*` (must classify as not-flagged — out of scope per design), policies mixing patterns, statements without an `Action` key, statements with `NotAction` (must not flag).

- **`iam-overpermissive-inline-policy` (Terraform).** Plan-mode tftest at `tests/plan.tftest.hcl` with ≥5 assertions per Rule 9. Assertions to include: Config rule resource type scope contains all three principal resource types, SSM document name follows the `name_prefix` convention, IAM role for SSM has at least the four expected permission statements (read principals, mutate inline, write S3 backup, query CloudTrail), `automatic_remediation` defaults to `false`, the precondition on `inline_backup_s3_bucket` triggers when a mutating mode is selected without a bucket.

- **`iam-policy-no-fullwildcard` (Terraform).** Plan-mode tftest at `tests/plan.tftest.hcl` with ≥5 assertions per Rule 9. Assertions to include: Config rule source identifier is `IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS`, remediation configuration targets the standard SSM document, `automatic_remediation` defaults to `false`, `name_prefix` is applied to all named resources, the `excluded_resource_ids` list is propagated to the remediation configuration parameters.

- **Dashboard module (HTML golden-file).** Render the dashboard against a fixture dataset containing one CMP finding and one inline finding from each pattern type, then compare the rendered HTML against a checked-in golden file. Regressions in table layout, severity color classes, or copy-CLI templating fail the test. Update the golden file deliberately when intended changes happen.

### Prior art for the tests

- **Plan-mode tftest prior art:** the existing `iam-wildcard-action-policy/tests/plan.tftest.hcl` is the canonical example. New modules' plan tests should follow the same shape (assertion count, attribute paths, naming conventions).

- **Lambda evaluator prior art:** the existing `iam-wildcard-action-policy/lambda/handler.py` is the structural prior art for the inline evaluator. The inline evaluator is a generalization of the same pattern — same `put_evaluation` shape, same URL-decoded-document handling, same compliance-type semantics — extended to walk multiple resource types and to recognize the bare `*` action that the existing handler deliberately filters out.

- **Dashboard golden-file prior art:** none currently in this repo. The dashboard module ships without tests today; this PRD introduces the convention. Recommended: place the golden file under `dashboard/tests/golden/` and the fixture dataset under `dashboard/tests/fixtures/`. Use a small Python script invoked from a `tftest` `run` block or a standalone `pytest` runner — whichever the maintainer prefers.

## Out of Scope

- **Resource-level scoping of recommended replacements.** Suggestions remain action-only. Resource ARNs and condition keys are not auto-derived from CloudTrail.

- **Prevention controls (SCPs, permission boundaries, IAM Access Analyzer policy validation).** This PRD ships detective and corrective controls only. Prevention is a separate workstream that depends on analyze data to decide what to deny.

- **Multi-account deployment topology.** v1 is single-account `terraform apply`. The multi-provider Terraform wrapper, AWS Organizations StackSets path, and AWS Config conformance-pack path are explicitly deferred.

- **Detection of policy patterns other than `Action: "*"` and `<service>:*`.** Verb-prefix wildcards (`s3:Get*`), `Resource: "*"` on dangerous verbs, `NotAction`/`NotResource` inversions, and trust-policy `Principal: "*"` patterns are not in scope. They are valid future additions and may warrant their own modules.

- **Auto-remediation of full wildcards in customer-managed policies.** The full-wildcard module ships with `tag-and-route` only; auto-scoping a `Action: "*"` from CloudTrail produces low-confidence policies and is intentionally not built.

- **Cross-account central S3 backup bucket.** The inline module's backup bucket lives in the same account as the principals being remediated for v1. A central GovCloud backup account with cross-account `s3:PutObject` is a follow-up.

- **Modifying the existing deployment pipeline.** The user does not have authority to change the central pipeline. All three modules must be deployable from a side configuration the security team owns.

- **Notifications / alerting integrations.** The dashboard is the v1 surface. Slack webhooks, EventBridge fan-out to email/PagerDuty, and CrowdStrike-back integrations are all deferred.

## Further Notes

- This work is driven by CrowdStrike alert volume in GovCloud and the operator-driven inability to fix the alert source (engineers bypass the central pipeline). The remediator pattern is detective-and-corrective by design; alert volume will not drop to zero until either prevention controls are added or the engineering culture around inline-policy creation shifts. Both of those are outside this PRD's scope.

- The design preferences captured during the grilling session — split modules over extension, conservative defaults, required-not-optional safety substrates, operator UX as a first-class requirement, deployment-staging via topology rather than module flags — are recorded as a feedback memory at `feedback_remediator_design_posture.md` and should guide future remediator design conversations.

- The existing module's `WildcardCategory` taxonomy (`Simple` / `Moderate` / `Complex`) does not directly map to the new severity classes (`CRIT` / `HIGH`). The category measures complexity-of-scoping; the severity measures blast-radius. Both will appear in the dashboard, but as separate columns/facets — they are not synonymous. Worth surfacing in `CONTEXT.md` once `/grill-with-docs` is run on this area.

- The inline module's exemption ID syntax (`<principal-type>/<name>[#<inline-policy-name>]`) is a new convention for this repo. It should be documented in the module README and in `CONTEXT.md` once that file exists, since other future modules over principal resource types may want to adopt it.

- The existing dashboard module's recent commit (`719113b`) scoped `config:GetComplianceDetailsByConfigRule` to a rule-id wildcard; this means the dashboard's IAM permission grant covers any new Config rule under the same naming convention without requiring a permission update when the new modules deploy.
