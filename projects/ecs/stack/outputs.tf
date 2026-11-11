output "url" {
  description = "Open this in a browser"
  value       = module.app.url
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

output "cluster_name" {
  value = module.app.cluster_name
}

output "log_group" {
  value = module.app.log_group
}
