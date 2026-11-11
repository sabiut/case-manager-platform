# Run once. Creates the S3 bucket that stores Terraform state for every project and region.
# This folder keeps its own state locally, because the bucket does not exist yet.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = { Product = "case-manager-lab", ManagedBy = "terraform", Stack = "bootstrap" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are global, so the account ID makes this one unique.
  bucket = "cm-platform-tfstate-${data.aws_caller_identity.current.account_id}"
}

# false (lab): "terraform destroy" here removes the bucket and every state file in it.
# true: the bucket cannot be destroyed while it holds state. Use this as soon as the state describes
# anything you could not afford to lose track of.
variable "protect_state" {
  type    = bool
  default = false
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket
  force_destroy = !var.protect_state
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" } # every state change keeps the previous copy
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Writes the bucket name to backend.hcl at the repo root.
# Every region folder reads it:  terraform init -backend-config=../../../backend.hcl
resource "local_file" "backend" {
  filename = "${path.module}/../backend.hcl"
  content  = "bucket = \"${aws_s3_bucket.state.bucket}\"\n"
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
