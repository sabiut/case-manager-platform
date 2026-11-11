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

variable "major_version" {
  description = "SQL Server major version. 16.00 is SQL Server 2022. Pinned so every region and every deploy gets the same one."
  type        = string
  default     = "16.00"
}

variable "protect_data" {
  description = <<-EOT
    false (lab): the database can be destroyed, no final snapshot is taken, buckets are emptied on destroy.
    true (real data): deletion protection on, a final snapshot is required, buckets cannot be force-emptied.
    This is separate from multi_az on purpose: high availability does not imply protection from deletion.
  EOT
  type        = bool
  default     = false
}
