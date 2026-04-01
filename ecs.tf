data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name_prefix}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_mtls_secrets" {
  count = var.create_private_ca && var.enable_workload_mtls_bundle ? 1 : 0

  name = "${local.name_prefix}-ecs-exec-mtls-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          for secret in aws_secretsmanager_secret.workload_mtls_bundle : "${secret.arn}*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy" "ecs_task_lattice_invoke" {
  name = "${local.name_prefix}-ecs-task-lattice-invoke"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["vpc-lattice-svcs:Invoke"]
        Resource = [for svc in aws_vpclattice_service.services : svc.arn]
      }
    ]
  })
}

resource "aws_ecs_cluster" "main" {
  name = var.ecs_cluster_name
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/aws/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "ecs_infrastructure_vpc_lattice" {
  name = "${local.name_prefix}-ecs-infra-lattice-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure_vpc_lattice" {
  role       = aws_iam_role.ecs_infrastructure_vpc_lattice.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForVpcLattice"
}

resource "time_sleep" "wait_for_ecs_infra_role" {
  depends_on = [aws_iam_role_policy_attachment.ecs_infrastructure_vpc_lattice]

  create_duration = "45s"
}

resource "aws_ecs_task_definition" "service" {
  for_each = var.services

  family                   = "${local.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = each.value.image
      essential = true
      portMappings = [
        {
          containerPort = each.value.container_port
          hostPort      = each.value.container_port
          protocol      = "tcp"
          name          = "app"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = each.key
        }
      }
      environment = [
        for env_key, env_value in(
          each.key == "dashboard" && local.dashboard_counting_url != null
          ? merge(
            {
              COUNTING_SERVICE_URL = local.dashboard_counting_url
              COUNTING_TLS_MODE    = var.dashboard_to_counting_mode == "lattice_https" ? "tls" : "disabled"
            },
            each.value.environment_vars
          )
          : each.value.environment_vars
          ) : {
          name  = env_key
          value = env_value
        }
      ]

      secrets = var.create_private_ca && var.enable_workload_mtls_bundle ? [
        {
          name      = "MTLS_BUNDLE_JSON"
          valueFrom = aws_secretsmanager_secret.workload_mtls_bundle[each.key].arn
        }
      ] : []
    }
  ])
}

resource "aws_ecs_service" "service" {
  for_each = var.services

  name            = "${local.name_prefix}-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services[each.key].arn
  }

  dynamic "load_balancer" {
    for_each = var.enable_public_dashboard && each.key == "dashboard" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.dashboard[0].arn
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  vpc_lattice_configurations {
    target_group_arn = aws_vpclattice_target_group.services[each.key].arn
    role_arn         = aws_iam_role.ecs_infrastructure_vpc_lattice.arn
    port_name        = "app"
  }

  depends_on = [
    time_sleep.wait_for_ecs_infra_role,
    aws_lb_listener.dashboard_http,
    aws_lb_listener.dashboard_https
  ]
}
