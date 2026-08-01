###############################################################################
# Module: iam
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

variable "bedrock_model_id" {
  description = "Bedrock model ID for IAM resource ARN"
  type        = string
}

# Resource ARNs passed in from other modules
variable "artifacts_bucket_arn" {
  description = "ARN of the S3 artifacts bucket"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB assessments table"
  type        = string
}

variable "agentcore_runtime_arn" {
  description = "ARN of the AgentCore Runtime (for ECS task invoke permission)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "KMS key ARN for S3/DynamoDB encryption"
  type        = string
}
