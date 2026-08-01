###############################################################################
# Module: ecs_ui
# Variables
###############################################################################

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB (2 required)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "ecs_ui_security_group_id" {
  description = "Security group ID for ECS UI tasks"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ECS task execution role ARN"
  type        = string
}

variable "task_role_arn" {
  description = "ECS task role ARN (runtime permissions)"
  type        = string
}

variable "ecr_ui_repository_url" {
  description = "ECR repository URL for the UI container image"
  type        = string
}

variable "agent_runtime_id" {
  description = "AgentCore Runtime ID passed to UI as env var"
  type        = string
}

variable "agent_endpoint_id" {
  description = "AgentCore Runtime Endpoint ID passed to UI for invoke URL"
  type        = string
}

variable "artifacts_bucket_name" {
  description = "S3 artifacts bucket name passed to UI as env var"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name passed to UI as env var"
  type        = string
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN for ALB authentication"
  type        = string
  default     = ""
}

variable "cognito_user_pool_client_id" {
  description = "Cognito App Client ID for ALB authentication"
  type        = string
  default     = ""
}

variable "cognito_user_pool_domain" {
  description = "Cognito hosted UI domain for ALB authentication"
  type        = string
  default     = ""
}

variable "enable_cognito_auth" {
  description = "Enable Cognito authentication on ALB (set false for initial testing)"
  type        = bool
  default     = false
}

variable "desired_count" {
  description = "Number of ECS task replicas"
  type        = number
  default     = 2
}

variable "cpu" {
  description = "ECS task CPU units"
  type        = number
  default     = 512
}

variable "memory" {
  description = "ECS task memory in MB"
  type        = number
  default     = 1024
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting CloudWatch logs"
  type        = string
}

