###############################################################################
# Module: ecr
# Outputs
###############################################################################

output "agent_repository_url" {
  description = "ECR repository URL for the agent container image"
  value       = aws_ecr_repository.agent.repository_url
}

output "agent_repository_name" {
  description = "ECR repository name for the agent"
  value       = aws_ecr_repository.agent.name
}

output "ui_repository_url" {
  description = "ECR repository URL for the UI container image"
  value       = aws_ecr_repository.ui.repository_url
}

output "ui_repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.ui.arn
}

output "ui_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.ui.name
}
