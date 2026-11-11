variable "name" {
  description = "Prefix for every resource name, for example cm-eks-au"
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets where Kubernetes places internet-facing load balancers"
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private subnets for the worker nodes"
  type        = list(string)
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  type    = number
  default = 2
}
