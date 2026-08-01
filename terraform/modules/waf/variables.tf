variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to protect with WAF"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
