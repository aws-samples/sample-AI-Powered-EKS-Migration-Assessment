###############################################################################
# Root: examples/production
# Outputs
###############################################################################

output "ui_url" {
  description = "URL of the assessment UI — open in browser to test"
  value       = module.ecs_ui.ui_url
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.ecs_ui.alb_dns_name
}

output "agent_runtime_id" {
  description = "AgentCore Runtime ID — use with invoke_agent.py"
  value       = module.agentcore_runtime.runtime_id
}

output "agent_runtime_arn" {
  description = "AgentCore Runtime ARN"
  value       = module.agentcore_runtime.runtime_arn
}

output "agent_endpoint_id" {
  description = "AgentCore Runtime Endpoint ID — the invoke URL identifier"
  value       = module.agentcore_endpoint.endpoint_id
}

output "memory_id" {
  description = "AgentCore Memory ID"
  value       = module.agentcore_memory.memory_id
}

output "s3_artifacts_bucket" {
  description = "S3 bucket for application artifacts"
  value       = module.storage.artifacts_bucket_id
}

output "dynamodb_table" {
  description = "DynamoDB assessments table name"
  value       = module.storage.dynamodb_table_name
}

output "ecr_ui_repository_url" {
  description = "ECR repository URL for UI container"
  value       = module.ecr.ui_repository_url
}

output "ecr_agent_repository_url" {
  description = "ECR repository URL for agent container"
  value       = module.ecr.agent_repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_ui.ecs_cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (empty if auth disabled)"
  value       = var.enable_cognito_auth ? module.cognito[0].user_pool_id : ""
}
