output "dashboard_url" {
  description = "Lambda Function URL (AWS_IAM auth) — bookmark this. Stakeholders access via SigV4-signed GET; the Lambda generates a fresh presigned S3 URL and returns 302."
  value       = aws_lambda_function_url.redirect.function_url
}

output "bucket_name" {
  description = "Name of the S3 bucket containing the rendered dashboard.html. Useful for debugging or direct CLI access (`aws s3 cp`, etc.)."
  value       = aws_s3_bucket.dashboard.id
}

output "refresh_lambda_function_name" {
  description = "Name of the refresh Lambda. Run `aws lambda invoke --function-name <name>` to force a refresh ahead of schedule."
  value       = aws_lambda_function.refresh.function_name
}

output "redirect_lambda_function_name" {
  description = "Name of the redirect Lambda. For ops debugging."
  value       = aws_lambda_function.redirect.function_name
}
