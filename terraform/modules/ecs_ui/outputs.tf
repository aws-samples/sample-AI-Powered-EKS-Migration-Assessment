###############################################################################
# Module: ecs_ui
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name - use this to access the UI"
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.this.arn
}

output "ui_url" {
  description = "Full URL of the assessment UI"
  value       = "http://${aws_lb.this.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.ui.name
}
