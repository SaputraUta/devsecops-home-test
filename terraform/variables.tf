variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-3"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-southeast-3a", "ap-southeast-3b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "github_repository" {
  type        = string
  description = "owner/repo allowed to assume the deploy role through OIDC"
  default     = "SaputraUta/devsecops-home-test"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate for the ALB HTTPS listener"
}

variable "alb_access_logs_bucket" {
  type        = string
  description = "Log archive bucket in the security account (Object Lock enabled)"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "app_image_tag" {
  type        = string
  description = "Image tag (commit SHA) the pipeline deploys"
  default     = "bootstrap"
}
