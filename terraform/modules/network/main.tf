# Private-only VPC that exists to give Aurora a subnet group. Nothing here
# routes to the internet: application Lambdas reach Aurora through the RDS
# Data API (HTTPS, IAM-authenticated), so there is no NAT gateway to pay for
# and no inbound path to the database at all.

# AZs are passed in explicitly rather than discovered: a lookup's result can
# change when AWS adds or retires a zone, which would make Terraform want to
# replace the subnets under a live Aurora cluster.
locals {
  azs = var.availability_zones
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

# Lock down the default SG so nothing accidentally inherits open rules.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_security_group" "db" {
  name        = "${var.name}-aurora"
  description = "Aurora cluster - no ingress; access is via RDS Data API only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-aurora" }
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = aws_subnet.private[*].id
}
