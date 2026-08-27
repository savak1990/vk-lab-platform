resource "aws_vpc" "this" {
  cidr_block = var.cidr_block
  # Not the default for a created VPC (unlike the AWS account's default
  # VPC) - EKS/kubelet's internal DNS resolution needs both.
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "public" {
  for_each = { for idx, az in var.availability_zones : az => idx }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr_block, 8, each.value)

  # No NAT Gateway (constitution §9 cost rule) - nodes need a public IP
  # to reach the EKS API/ECR/pull images without one.
  map_public_ip_on_launch = true

  tags = {
    # Lets aws-load-balancer-controller auto-discover these subnets for
    # internet-facing NLBs/Services without an explicit subnet annotation.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
