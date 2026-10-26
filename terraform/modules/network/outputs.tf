output "vpc_id" {
  value = aws_vpc.this.id
}

output "db_subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}
