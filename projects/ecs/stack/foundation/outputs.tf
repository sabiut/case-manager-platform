output "vpc_id" {
  value = module.network.vpc_id
}

output "db_address" {
  value = module.database.address
}

output "db_secret_arn" {
  value = module.database.master_secret_arn
}

output "app_db_secret_arn" {
  value = module.database.app_secret_arn
}

output "migration_bucket" {
  value = module.database.migration_bucket
}

output "ecr_web_repository_url" {
  value = module.registry_web.repository_url
}

output "ecr_api_repository_url" {
  value = module.registry_api.repository_url
}
