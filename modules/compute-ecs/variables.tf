variable "name" {
  description = "Prefix for every resource name, for example cm-ecs-au"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets for the internet-facing load balancer"
  type        = list(string)
}

variable "web_subnet_ids" {
  description = "Private subnets for the frontend containers"
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private subnets for the internal load balancer and the backend API containers"
  type        = list(string)
}

variable "web_image" {
  description = "Frontend image. Empty means a placeholder web server until the real app is pushed."
  type        = string
  default     = ""
}

variable "api_image" {
  description = "Backend API image. Empty means a placeholder web server until the real app is pushed."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Port both containers listen on"
  type        = number
  default     = 80
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "desired_count" {
  description = "How many copies of each service to run. Two or more, so one zone can fail."
  type        = number
  default     = 2
}

variable "db_host" {
  type = string
}

variable "app_db_secret_arn" {
  description = "Secret with the API's restricted database login"
  type        = string
}

variable "admin_db_secret_arn" {
  description = "Secret with the database admin login. Given only to the migration task, never to a running service."
  type        = string
}

variable "db_name" {
  description = "The customer database the API reads"
  type        = string
  default     = "demo"
}

variable "region_code" {
  description = "au, uk or us. Shown on the page."
  type        = string
}
