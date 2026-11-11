# United States (N. Virginia), app layer. Its own state file. Nothing is shared with other regions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # The bucket name comes from backend.hcl:  terraform init -backend-config=../../../../backend.hcl
  backend "s3" {
    key          = "ecs/us/app.tfstate"
    region       = "ap-southeast-2" # where the state bucket lives, not where this stack deploys
    encrypt      = true
    use_lockfile = true # stops two applies running at the same time
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Product     = "case-manager-lab"
      Project     = "ecs"
      Region      = "us"
      Layer       = "app"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

variable "image_tag" {
  description = "Image tag to deploy. Empty runs a placeholder web server."
  type        = string
  default     = ""
}

module "stack" {
  source      = "../../stack/app"
  region_code = "us"
  image_tag   = var.image_tag
}

output "url" { value = module.stack.url }
output "cluster_name" { value = module.stack.cluster_name }
output "service_name" { value = module.stack.service_name }
output "log_group" { value = module.stack.log_group }
output "task_definition_arn" { value = module.stack.task_definition_arn }
output "migrate_task_definition_arn" { value = module.stack.migrate_task_definition_arn }
output "run_task_network" { value = module.stack.run_task_network }
