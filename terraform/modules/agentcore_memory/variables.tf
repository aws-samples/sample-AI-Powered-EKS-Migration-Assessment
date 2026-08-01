###############################################################################
# Module: agentcore_memory
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

variable "execution_role_arn" {
  description = "IAM role ARN for memory execution (model inference for strategies)"
  type        = string
}

variable "event_expiry_days" {
  description = "Number of days after which memory events expire (7-365)"
  type        = number
  default     = 90
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
