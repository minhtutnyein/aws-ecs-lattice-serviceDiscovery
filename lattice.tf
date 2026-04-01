resource "aws_vpclattice_service_network" "main" {
  name      = "${local.name_prefix}-network"
  auth_type = var.vpc_lattice_auth_type

  tags = {
    Name = "${local.name_prefix}-network"
  }
}

resource "aws_vpclattice_service_network_vpc_association" "main" {
  service_network_identifier = aws_vpclattice_service_network.main.id
  vpc_identifier             = aws_vpc.main.id
  security_group_ids         = [aws_security_group.vpc_lattice.id]

  tags = {
    Name = "${local.name_prefix}-network-vpc-assoc"
  }
}

resource "aws_vpclattice_service" "services" {
  for_each = var.services

  name      = "${local.name_prefix}-${each.key}"
  auth_type = var.vpc_lattice_auth_type

  tags = {
    Name = "${local.name_prefix}-${each.key}-lattice"
  }
}

resource "aws_vpclattice_target_group" "services" {
  for_each = var.services

  name = "${local.name_prefix}-${each.key}-${each.value.container_port}"
  type = "IP"

  lifecycle {
    create_before_destroy = true
  }

  config {
    protocol       = "HTTP"
    port           = each.value.container_port
    vpc_identifier = aws_vpc.main.id

    health_check {
      enabled                       = true
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      protocol                      = "HTTP"
      port                          = each.value.container_port
      path                          = each.value.health_path

      matcher {
        value = "200-499"
      }
    }
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}-tg"
  }
}

resource "aws_vpclattice_listener" "services" {
  for_each = var.services

  name               = "${each.key}-listener"
  service_identifier = aws_vpclattice_service.services[each.key].id
  protocol           = var.lattice_listener_protocol
  port               = var.lattice_listener_port

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.services[each.key].id
        weight                  = 100
      }
    }
  }
}

resource "aws_cloudwatch_log_group" "lattice_access" {
  count = var.enable_lattice_access_logs ? 1 : 0

  name              = "/aws/vpclattice/${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_vpclattice_access_log_subscription" "services" {
  for_each = var.enable_lattice_access_logs ? aws_vpclattice_service.services : {}

  resource_identifier = each.value.id
  destination_arn     = aws_cloudwatch_log_group.lattice_access[0].arn
}

resource "aws_vpclattice_service_network_service_association" "services" {
  for_each = var.services

  service_network_identifier = aws_vpclattice_service_network.main.id
  service_identifier         = aws_vpclattice_service.services[each.key].id

  tags = {
    Name = "${local.name_prefix}-${each.key}-network-assoc"
  }
}

data "aws_iam_policy_document" "lattice_service_auth" {
  for_each = var.enable_lattice_auth_policy && var.vpc_lattice_auth_type == "AWS_IAM" ? var.services : {}

  statement {
    sid    = "AllowInvokeFromApprovedPrincipals"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = distinct(concat(
        [aws_iam_role.ecs_task.arn],
        var.allowed_lattice_invoke_principal_arns
      ))
    }

    actions   = ["vpc-lattice-svcs:Invoke"]
    resources = [aws_vpclattice_service.services[each.key].arn]
  }
}

resource "aws_vpclattice_auth_policy" "services" {
  for_each = data.aws_iam_policy_document.lattice_service_auth

  resource_identifier = aws_vpclattice_service.services[each.key].arn
  policy              = each.value.json
}
