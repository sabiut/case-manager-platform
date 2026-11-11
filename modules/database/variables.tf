variable "name" {
  description = "Prefix for every resource name, for example cm-ecs-au"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Database subnets, in at least two availability zones"
  type        = list(string)
}

variable "engine" {
  description = "sqlserver-ex (Express, lab) or sqlserver-se (Standard, production)"
  type        = string
  default     = "sqlserver-ex"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Standby copy in a second zone. Not available on Express edition."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automated backups and point-in-time restore"
  type        = number
  default     = 7
}

variable "lab_mode" {
  description = "true: can be destroyed without a final snapshot. false: protected from deletion."
  type        = bool
  default     = true
}
