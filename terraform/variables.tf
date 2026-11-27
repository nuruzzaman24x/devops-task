variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "devops-task"
}

variable "environment" {
  type        = string
  description = "staging or prod"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "app_port" {
  type    = number
  default = 8080
}

variable "allowed_cidr" {
  type        = list(string)
  description = "CIDRs allowed to reach the app port"
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "initial_image_tag" {
  type        = string
  description = "Image tag to run at first boot. Empty = do not start a container yet."
  default     = ""
}
