output "dashboard_url" {
  description = "Lambda Function URL — bookmark this."
  value       = module.iam_wildcard_dashboard.dashboard_url
}

output "bucket_name" {
  description = "Dashboard S3 bucket name."
  value       = module.iam_wildcard_dashboard.bucket_name
}

output "refresh_lambda_function_name" {
  description = "Refresh Lambda function name."
  value       = module.iam_wildcard_dashboard.refresh_lambda_function_name
}

output "redirect_lambda_function_name" {
  description = "Redirect Lambda function name."
  value       = module.iam_wildcard_dashboard.redirect_lambda_function_name
}
