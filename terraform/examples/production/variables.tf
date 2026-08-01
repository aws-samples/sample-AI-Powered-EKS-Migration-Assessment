###############################################################################
# Root: examples/production
# Input variables
###############################################################################

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name — used as prefix for all resources"
  type        = string
  default     = "eks-migration-agent"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID for the assessment agent"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-20250514"
}

variable "log_level" {
  description = "Log level for Lambda functions and agent"
  type        = string
  default     = "INFO"
}

variable "ecs_desired_count" {
  description = "Number of ECS UI task replicas"
  type        = number
  default     = 2
}

variable "allowed_cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to access the ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_ipv6_cidr_blocks" {
  description = "IPv6 CIDR blocks allowed to access the ALB"
  type        = list(string)
  default     = []
}

variable "enable_cognito_auth" {
  description = "Enable Cognito User Pool authentication for UI. Set to true for production."
  type        = bool
  default     = false
}

