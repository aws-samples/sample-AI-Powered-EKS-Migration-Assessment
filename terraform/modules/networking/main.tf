###############################################################################
# Module: networking
# VPC, subnets, internet gateway, NAT gateway, route tables, security groups
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

###############################################################################
# Internet Gateway
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

###############################################################################
# Public Subnets (2 AZs for ALB)
###############################################################################

resource "aws_subnet" "public" {
  #tfsec:ignore:aws-ec2-no-public-ip-subnet - Public subnets required for internet-facing ALB
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 100 + count.index)
  ipv6_cidr_block         = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 100 + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  assign_ipv6_address_on_creation = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${count.index}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Private Subnets (2 AZs for ECS tasks)
###############################################################################

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-${count.index}"
    Tier = "private"
  })
}

###############################################################################
# NAT Gateway (single, in first public subnet)
###############################################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# Security Groups
###############################################################################

# ALB security group - allows inbound HTTP/HTTPS from allowed CIDRs
resource "aws_security_group" "alb" {
  #tfsec:ignore:aws-ec2-no-public-ingress-sgr - ALB must accept traffic from allowed CIDRs (configurable)
  name_prefix = "${var.project_name}-alb-"
  vpc_id      = aws_vpc.this.id
  description = "ALB inbound HTTP/HTTPS from allowed CIDRs"

  ingress {
    description      = "HTTPS from allowed CIDRs"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = var.allowed_cidr_blocks
    ipv6_cidr_blocks = var.allowed_ipv6_cidr_blocks
  }

  ingress {
    description      = "HTTP from allowed CIDRs"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = var.allowed_cidr_blocks
    ipv6_cidr_blocks = var.allowed_ipv6_cidr_blocks
  }

  egress {
    description = "Allow outbound to ECS tasks"
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-alb-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ECS UI security group - allows inbound only from ALB
resource "aws_security_group" "ecs_ui" {
  name_prefix = "${var.project_name}-ecs-ui-"
  vpc_id      = aws_vpc.this.id
  description = "ECS UI tasks - inbound from ALB only"

  ingress {
    description     = "Streamlit from ALB"
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    #tfsec:ignore:aws-ec2-no-public-egress-sgr - ECS tasks need HTTPS to AWS services (S3, DynamoDB, Bedrock, ECR)
    description = "HTTPS to AWS services (S3, DynamoDB, Bedrock, ECR)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-ecs-ui-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
