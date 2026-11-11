variable "name" {
  description = "Prefix for every resource name, for example cm-ec2-au"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets for the load balancer"
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private subnets for the servers"
  type        = list(string)
}

variable "instance_type" {
  description = "Windows Server needs at least 4 GB of memory to be comfortable"
  type        = string
  default     = "t3.medium"
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "db_host" {
  type = string
}

variable "db_secret_arn" {
  description = "Secret with the web app's restricted database login (never the admin login)"
  type        = string
}
