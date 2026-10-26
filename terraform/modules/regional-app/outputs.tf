output "function_name" {
  value = aws_lambda_function.app.function_name
}

output "function_arn" {
  value = aws_lambda_function.app.arn
}

output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "default_endpoint" {
  description = "Region-pinned execute-api URL (no trailing slash)."
  value       = trimsuffix(aws_apigatewayv2_api.this.api_endpoint, "/")
}

output "default_endpoint_host" {
  value = trimprefix(aws_apigatewayv2_api.this.api_endpoint, "https://")
}

output "domain_target" {
  description = "Regional custom-domain target for the Route 53 alias."
  value       = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
}

output "domain_zone_id" {
  value = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].hosted_zone_id
}
