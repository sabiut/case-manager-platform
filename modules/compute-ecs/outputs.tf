output "url" {
  value = "http://${aws_lb.this.dns_name}"
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "load_balancer_arn" {
  value = aws_lb.this.arn
}

output "task_definition_arn" {
  description = "The exact version this deployment asked ECS to run"
  value       = aws_ecs_task_definition.app.arn
}

output "migrate_task_definition_arn" {
  description = "Empty when the placeholder web server is deployed"
  value       = try(aws_ecs_task_definition.migrate[0].arn, "")
}

output "run_task_network" {
  description = "Network settings for running the migration task with aws ecs run-task"
  value = jsonencode({
    awsvpcConfiguration = {
      subnets        = var.app_subnet_ids
      securityGroups = [aws_security_group.app.id]
      assignPublicIp = "DISABLED"
    }
  })
}
