resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "ECS task security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow service traffic from VPC Lattice"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_lattice.id]
  }

  ingress {
    description = "Allow in-VPC service traffic (Lattice data plane source compatibility)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Allow VPC Lattice link-local health/data plane traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["169.254.171.0/24"]
  }

  ingress {
    description = "Allow service-to-service east-west traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  dynamic "ingress" {
    for_each = var.enable_public_dashboard ? [1] : []
    content {
      description     = "Allow dashboard traffic from ALB"
      from_port       = local.dashboard_port
      to_port         = local.dashboard_port
      protocol        = "tcp"
      security_groups = [aws_security_group.dashboard_alb[0].id]
    }
  }

  egress {
    description = "Allow Lattice link-local HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["169.254.171.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ecs-tasks-sg"
  }
}

resource "aws_security_group" "dashboard_alb" {
  count = var.enable_public_dashboard ? 1 : 0

  name        = "${local.name_prefix}-dashboard-alb-sg"
  description = "Public ALB security group for dashboard"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from internet"
    from_port   = var.public_dashboard_listener_port
    to_port     = var.public_dashboard_listener_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from internet"
    from_port   = var.public_dashboard_https_port
    to_port     = var.public_dashboard_https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-dashboard-alb-sg"
  }
}

resource "aws_security_group" "vpc_lattice" {
  name        = "${local.name_prefix}-lattice-sg"
  description = "VPC Lattice traffic security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow traffic from inside VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-lattice-sg"
  }
}
