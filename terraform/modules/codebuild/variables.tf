###############################################################################
# Module: codebuild
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

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "agent_ecr_repository_url" {
  description = "ECR repository URL for the agent image"
  type        = string
}

variable "ui_ecr_repository_url" {
  description = "ECR repository URL for the UI image"
  type        = string
}

variable "source_bucket_name" {
  description = "S3 bucket to store build source archives"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for S3 encryption"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "agent_source_hash" {
  description = "Hash of agent source zip to trigger rebuilds only when code changes"
  type        = string
  default     = "initial"
}

variable "ui_source_hash" {
  description = "Hash of UI source zip to trigger rebuilds only when code changes"
  type        = string
  default     = "initial"
}
