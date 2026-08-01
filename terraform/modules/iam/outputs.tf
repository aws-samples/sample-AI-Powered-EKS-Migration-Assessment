###############################################################################
# Module: iam
# Outputs
###############################################################################

output "agentcore_execution_role_arn" {
  description = "ARN of the AgentCore Runtime execution role"
  value       = aws_iam_role.agentcore_execution.arn
}

output "agentcore_execution_role_name" {
  description = "Name of the AgentCore Runtime execution role"
  value       = aws_iam_role.agentcore_execution.name
}

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role (runtime permissions)"
  value       = aws_iam_role.ecs_task.arn
}
