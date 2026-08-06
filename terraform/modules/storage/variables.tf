###############################################################################
# Module: storage
# Variables
###############################################################################

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]{1,40}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-42 lowercase alphanumeric characters or hyphens, and must start/end with a letter or number (e.g. 'eks-migration-agent')."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for unique bucket naming"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID. Ensure your AWS credentials are configured correctly."
  }
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for encrypting S3, DynamoDB, and CloudWatch"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
