output "url" {
  value = "http://${aws_lb.this.dns_name}"
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "autoscaling_group" {
  value = aws_autoscaling_group.app.name
}
