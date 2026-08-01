###############################################################################
# Module: storage
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

variable "aws_account_id" {
  description = "AWS account ID for unique bucket naming"
  type        = string
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
