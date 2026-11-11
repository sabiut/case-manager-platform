output "cluster_name" {
  value = module.app.cluster_name
}

output "db_address" {
  value = module.database.address
}

output "db_secret_arn" {
  value = module.database.master_secret_arn
}

output "migration_bucket" {
  value = module.database.migration_bucket
}

output "ecr_repository_url" {
  value = module.app.ecr_repository_url
}
