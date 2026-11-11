output "url" {
  description = "Open this in a browser"
  value       = module.app.url
}

output "cluster_name" {
  value = module.app.cluster_name
}

output "service_name" {
  value = module.app.service_name
}

output "log_group" {
  value = module.app.log_group
}

output "task_definition_arn" {
  value = module.app.task_definition_arn
}

output "migrate_task_definition_arn" {
  value = module.app.migrate_task_definition_arn
}

output "run_task_network" {
  value = module.app.run_task_network
}
