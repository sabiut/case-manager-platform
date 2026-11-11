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

output "autoscaling_groups" {
  value = { for tier, group in aws_autoscaling_group.tier : tier => group.name }
}

output "load_balancer_arn" {
  description = "The internet-facing load balancer, for the web application firewall"
  value       = aws_lb.web.arn
}
