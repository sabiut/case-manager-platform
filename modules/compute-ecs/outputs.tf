output "url" {
  value = "http://${aws_lb.web.dns_name}"
}

output "api_internal_url" {
  description = "Reachable only from inside the VPC"
  value       = "http://${aws_lb.api.dns_name}"
}

output "api_security_group_id" {
  description = "The only security group allowed into the database"
  value       = aws_security_group.api.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "load_balancer_arn" {
  description = "The internet-facing load balancer, for the web application firewall"
  value       = aws_lb.web.arn
}

output "web_task_definition_arn" {
  description = "The exact frontend version this deployment asked ECS to run"
  value       = aws_ecs_task_definition.web.arn
}

output "api_task_definition_arn" {
  description = "The exact API version this deployment asked ECS to run"
  value       = aws_ecs_task_definition.api.arn
}
