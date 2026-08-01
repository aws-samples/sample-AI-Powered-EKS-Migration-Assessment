###############################################################################
# Module: agentcore_runtime
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

variable "execution_role_arn" {
  description = "IAM role ARN for AgentCore Runtime execution"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for the agent container image"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID passed to agent as env var"
  type        = string
}

variable "artifacts_bucket_name" {
  description = "S3 artifacts bucket name passed to agent as env var"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name passed to agent as env var"
  type        = string
}

variable "memory_id" {
  description = "AgentCore Memory ID passed to agent as env var"
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Log level for the agent"
  type        = string
  default     = "INFO"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "image_tag" {
  description = "Docker image tag for the agent container (use hash for cache-busting)"
  type        = string
  default     = "latest"
}

variable "deploy_version" {
  description = "Deploy version timestamp to force AgentCore Runtime image re-pull"
  type        = string
  default     = "1"
}
