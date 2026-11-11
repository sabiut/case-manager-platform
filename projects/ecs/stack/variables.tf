variable "region_code" {
  description = "Short name used in every resource name: au, uk or us"
  type        = string
}

variable "cidr" {
  description = "VPC range. Different in every region so the networks never overlap."
  type        = string
}

variable "image" {
  description = "Container image. Empty runs a placeholder web server."
  type        = string
  default     = ""
}

variable "container_port" {
  type    = number
  default = 80
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "db_multi_az" {
  description = "Needs Standard edition (sqlserver-se). Express does not support it."
  type        = bool
  default     = false
}

variable "db_engine" {
  type    = string
  default = "sqlserver-ex"
}
