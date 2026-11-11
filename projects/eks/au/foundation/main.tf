# Australia (Sydney), foundation layer. Its own state file. Nothing is shared with other regions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # The bucket name comes from backend.hcl:  terraform init -backend-config=../../../../backend.hcl
  backend "s3" {
    key          = "eks/au/foundation.tfstate"
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
      Project     = "eks"
      Region      = "au"
      Layer       = "foundation"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

# Database settings. Defaults are SQL Server Standard with a standby in a second zone.
variable "db_engine" {
  type    = string
  default = "sqlserver-se"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.xlarge"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

# false = lab (can be destroyed). true = real data (deletion protection and final snapshot).
variable "protect_data" {
  type    = bool
  default = false
}

module "stack" {
  source            = "../../stack/foundation"
  region_code       = "au"
  cidr              = "10.10.0.0/16"
  db_engine         = var.db_engine
  db_instance_class = var.db_instance_class
  db_multi_az       = var.db_multi_az
  protect_data      = var.protect_data
}

output "vpc_id" { value = module.stack.vpc_id }
output "db_address" { value = module.stack.db_address }
output "db_secret_arn" { value = module.stack.db_secret_arn }
output "app_db_secret_arn" { value = module.stack.app_db_secret_arn }
output "migration_bucket" { value = module.stack.migration_bucket }
output "ecr_web_repository_url" { value = module.stack.ecr_web_repository_url }
output "ecr_api_repository_url" { value = module.stack.ecr_api_repository_url }
