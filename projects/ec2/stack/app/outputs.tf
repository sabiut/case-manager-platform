output "url" {
  description = "Open this in a browser (Windows servers need about 10 minutes after apply)"
  value       = module.app.url
}

output "api_internal_url" {
  description = "The backend API tier. Reachable only from inside the VPC."
  value       = module.app.api_internal_url
}

output "autoscaling_groups" {
  value = module.app.autoscaling_groups
}
