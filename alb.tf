resource "aws_lb" "dashboard" {
  count = var.enable_public_dashboard ? 1 : 0

  name               = "${local.name_prefix}-dashboard"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.dashboard_alb[0].id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${local.name_prefix}-dashboard-alb"
  }
}

resource "aws_lb_target_group" "dashboard" {
  count = var.enable_public_dashboard ? 1 : 0

  name                 = "${local.name_prefix}-dash-${local.dashboard_port}"
  port                 = local.dashboard_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 10

  lifecycle {
    create_before_destroy = true
  }

  health_check {
    path                = local.dashboard_health_path
    protocol            = "HTTP"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-dashboard-tg"
  }
}

resource "aws_lb_listener" "dashboard_http" {
  count = var.enable_public_dashboard ? 1 : 0

  load_balancer_arn = aws_lb.dashboard[0].arn
  port              = var.public_dashboard_listener_port
  protocol          = "HTTP"

  default_action {
    type = var.create_private_ca && var.redirect_http_to_https ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.create_private_ca && var.redirect_http_to_https ? [1] : []
      content {
        port        = tostring(var.public_dashboard_https_port)
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = var.create_private_ca && var.redirect_http_to_https ? [] : [1]
      content {
        target_group {
          arn    = aws_lb_target_group.dashboard[0].arn
          weight = 100
        }
      }
    }
  }
}

resource "aws_lb_listener" "dashboard_https" {
  count = var.enable_public_dashboard && var.create_private_ca ? 1 : 0

  load_balancer_arn = aws_lb.dashboard[0].arn
  port              = var.public_dashboard_https_port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.service["dashboard"].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dashboard[0].arn
  }
}
