# Australia (Sydney). Its own state file, its own network range, nothing shared with other regions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # The bucket name comes from backend.hcl:  terraform init -backend-config=../../../backend.hcl
  backend "s3" {
    key          = "ecs/au/terraform.tfstate"
    region       = "ap-southeast-2" # where the state bucket lives, not where this stack deploys
    encrypt      = true
    use_lockfile = true # stops two applies running at the same time
  }
}

provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = {
      Product     = "case-manager-lab"
      Project     = "ecs"
      Region      = "au"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

variable "image" {
  description = "Container image to deploy. Empty runs a placeholder web server."
  type        = string
  default     = ""
}

module "stack" {
  source      = "../stack"
  region_code = "au"
  cidr        = "10.10.0.0/16"
  image       = var.image
}

output "url" { value = module.stack.url }
output "db_address" { value = module.stack.db_address }
output "db_secret_arn" { value = module.stack.db_secret_arn }
output "migration_bucket" { value = module.stack.migration_bucket }
output "ecr_repository_url" { value = module.stack.ecr_repository_url }
output "cluster_name" { value = module.stack.cluster_name }
output "log_group" { value = module.stack.log_group }
