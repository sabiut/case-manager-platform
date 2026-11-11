# United Kingdom (London), app layer. Its own state file. Nothing is shared with other regions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # The bucket name comes from backend.hcl:  terraform init -backend-config=../../../../backend.hcl
  backend "s3" {
    key          = "ec2/uk/app.tfstate"
    region       = "ap-southeast-2" # where the state bucket lives, not where this stack deploys
    encrypt      = true
    use_lockfile = true # stops two applies running at the same time
  }
}

provider "aws" {
  region = "eu-west-2"
  default_tags {
    tags = {
      Product     = "case-manager-lab"
      Project     = "ec2"
      Region      = "uk"
      Layer       = "app"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

module "stack" {
  source      = "../../stack/app"
  region_code = "uk"
}

output "url" { value = module.stack.url }
output "autoscaling_group" { value = module.stack.autoscaling_group }
