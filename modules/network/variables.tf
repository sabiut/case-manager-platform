variable "name" {
  description = "Prefix for every resource name, for example cm-ecs-au"
  type        = string
}

variable "cidr" {
  description = "IP range of the VPC. Must be different in every region."
  type        = string
}

variable "az_count" {
  description = "How many availability zones to spread across"
  type        = number
  default     = 2
}
