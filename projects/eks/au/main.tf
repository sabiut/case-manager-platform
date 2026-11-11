# Australia (Sydney). Its own state file, its own network range, nothing shared with other regions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # The bucket name comes from backend.hcl:  terraform init -backend-config=../../../backend.hcl
  backend "s3" {
    key          = "eks/au/terraform.tfstate"
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
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

# Database settings. Defaults are the cheap lab setup (Express, one zone).
# For a Multi-AZ test:  terraform apply -var db_engine=sqlserver-se -var db_instance_class=<class> -var db_multi_az=true
variable "db_engine" {
  type    = string
  default = "sqlserver-ex"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

module "stack" {
  source            = "../stack"
  region_code       = "au"
  cidr              = "10.10.0.0/16"
  db_engine         = var.db_engine
  db_instance_class = var.db_instance_class
  db_multi_az       = var.db_multi_az
}

output "cluster_name" { value = module.stack.cluster_name }
output "db_address" { value = module.stack.db_address }
output "db_secret_arn" { value = module.stack.db_secret_arn }
output "migration_bucket" { value = module.stack.migration_bucket }
output "ecr_repository_url" { value = module.stack.ecr_repository_url }
