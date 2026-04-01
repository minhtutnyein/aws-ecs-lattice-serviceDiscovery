data "archive_file" "lattice_target_reconciler_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lattice_target_reconciler.py"
  output_path = "${path.module}/lambda/lattice_target_reconciler.zip"
}

resource "aws_iam_role" "lattice_reconciler_lambda" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  name = "${local.name_prefix}-lattice-reconciler-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lattice_reconciler_lambda" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  name = "${local.name_prefix}-lattice-reconciler-lambda-policy"
  role = aws_iam_role.lattice_reconciler_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "vpc-lattice:RegisterTargets",
          "vpc-lattice:DeregisterTargets"
        ]
        Resource = [for tg in aws_vpclattice_target_group.services : tg.arn]
      }
    ]
  })
}

resource "aws_lambda_function" "lattice_target_reconciler" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  function_name = "${local.name_prefix}-lattice-target-reconciler"
  role          = aws_iam_role.lattice_reconciler_lambda[0].arn
  handler       = "lattice_target_reconciler.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.lattice_target_reconciler_zip.output_path
  source_code_hash = data.archive_file.lattice_target_reconciler_zip.output_base64sha256

  timeout = 30

  environment {
    variables = {
      SERVICE_TARGET_GROUP_MAP = jsonencode(merge(
        { for k, v in aws_vpclattice_target_group.services : k => v.id },
        { for k, v in aws_vpclattice_target_group.services : "${local.name_prefix}-${k}" => v.id }
      ))
      SERVICE_PORT_MAP = jsonencode(merge(
        { for k, v in var.services : k => v.container_port },
        { for k, v in var.services : "${local.name_prefix}-${k}" => v.container_port }
      ))
    }
  }

  depends_on = [aws_iam_role_policy.lattice_reconciler_lambda]
}

resource "aws_cloudwatch_event_rule" "ecs_task_state_change" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  name        = "${local.name_prefix}-ecs-task-state-change"
  description = "Forward ECS task state changes to Lattice target reconciler"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.main.arn]
      lastStatus = ["RUNNING", "STOPPED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_state_change_lambda" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_task_state_change[0].name
  target_id = "lattice-target-reconciler"
  arn       = aws_lambda_function.lattice_target_reconciler[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  count = var.enable_eventbridge_lambda_reconciler ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lattice_target_reconciler[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_task_state_change[0].arn
}
