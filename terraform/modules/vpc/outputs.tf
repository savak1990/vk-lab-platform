output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "public_subnet_ids_by_az" {
  value = { for az, s in aws_subnet.public : az => s.id }
}
