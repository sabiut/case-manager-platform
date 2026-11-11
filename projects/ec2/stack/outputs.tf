output "url" {
  description = "Open this in a browser (Windows servers need about 10 minutes after apply)"
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

output "autoscaling_group" {
  value = module.app.autoscaling_group
}
