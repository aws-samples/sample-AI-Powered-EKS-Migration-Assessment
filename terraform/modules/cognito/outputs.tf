###############################################################################
# Module: cognito
# Outputs
###############################################################################

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.this.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint"
  value       = aws_cognito_user_pool.this.endpoint
}

output "app_client_id" {
  description = "Cognito App Client ID (used by ALB)"
  value       = aws_cognito_user_pool_client.alb.id
}

output "app_client_secret" {
  description = "Cognito App Client secret (used by ALB)"
  value       = aws_cognito_user_pool_client.alb.client_secret
  sensitive   = true
}

output "hosted_ui_domain" {
  description = "Cognito hosted UI domain"
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${split(":", aws_cognito_user_pool.this.arn)[3]}.amazoncognito.com"
}
