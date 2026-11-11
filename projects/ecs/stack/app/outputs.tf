output "url" {
  description = "Open this in a browser"
  value       = module.app.url
}

output "api_internal_url" {
  description = "The backend API. Reachable only from inside the VPC."
  value       = module.app.api_internal_url
}

output "cluster_name" {
  value = module.app.cluster_name
}

output "log_group" {
  value = module.app.log_group
}

output "web_task_definition_arn" {
  value = module.app.web_task_definition_arn
}

output "api_task_definition_arn" {
  value = module.app.api_task_definition_arn
}
