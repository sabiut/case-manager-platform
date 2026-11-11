variable "region_code" {
  description = "Short name used in every resource name: au, uk or us"
  type        = string
}

variable "cidr" {
  description = "VPC range. Different in every region so the networks never overlap."
  type        = string
}

variable "db_engine" {
  description = "sqlserver-ex (Express) or sqlserver-se (Standard)"
  type        = string
  default     = "sqlserver-se"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.xlarge"
}

variable "db_multi_az" {
  description = "Needs Standard edition. Express does not support it."
  type        = bool
  default     = true
}

variable "protect_data" {
  description = "true for real data: deletion protection, final snapshot, buckets not force-emptied"
  type        = bool
  default     = false
}
