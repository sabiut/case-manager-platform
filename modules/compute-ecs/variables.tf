variable "name" {
  description = "Prefix for every resource name, for example cm-ecs-au"
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
  description = "Private subnets for the containers"
  type        = list(string)
}

variable "image" {
  description = "Container image to run. Empty means a placeholder web server until the real app is pushed."
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

variable "desired_count" {
  description = "How many copies of the app to run. Two or more, so one zone can fail."
  type        = number
  default     = 2
}

variable "db_host" {
  type = string
}

variable "app_db_secret_arn" {
  description = "Secret with the web app's restricted database login"
  type        = string
}

variable "admin_db_secret_arn" {
  description = "Secret with the database admin login. Given only to the migration task, never to the web app."
  type        = string
}

variable "db_name" {
  description = "The customer database the app reads"
  type        = string
  default     = "demo"
}

variable "region_code" {
  description = "au, uk or us. Shown on the app page."
  type        = string
}
