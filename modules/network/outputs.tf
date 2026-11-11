output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "web_subnet_ids" {
  value = aws_subnet.web[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "database_subnet_ids" {
  value = aws_subnet.database[*].id
}
