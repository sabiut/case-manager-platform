output "url" {
  description = "Open this in a browser (Windows servers need about 10 minutes after apply)"
  value       = module.app.url
}

output "autoscaling_group" {
  value = module.app.autoscaling_group
}
