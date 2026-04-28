# Basic example — `iam-wildcard-action-policy-dashboard`

Minimal deployment of the dashboard module pointing at an existing
`iam-wildcard-action-policy` Config rule.

## Usage

```hcl
module "iam_wildcard_dashboard" {
  source           = "../../"
  name_prefix      = "crwd"
  config_rule_name = "crwd-iam-wildcard-action-policy"
}
```

After apply, bookmark the `dashboard_url` output. Stakeholders access via
SigV4-signed GET (browser plugin, `awscurl`, or AWS CLI).
