variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "employee-portal"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "tier5"
}
