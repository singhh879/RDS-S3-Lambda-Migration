# ──────────────────────────────────────────────
# Lambda Chain Pipeline (Alternative to Step Functions)
# ──────────────────────────────────────────────
# FLOW:
#   EventBridge → Orchestrator Lambda (starts ECS)
#       → ECS uploads manifest.json to S3
#       → S3 event triggers Verification Lambda
#       → If passed, writes verified.json
#       → S3 event triggers Drop Partition Lambda
#
# Both pipelines share the same verify + drop Lambdas.
# TO USE THIS: trigger orchestrator Lambda
# TO USE STEP FUNCTIONS: trigger the state machine
# Enable ONLY ONE EventBridge schedule at a time.
# ──────────────────────────────────────────────


# ─── Package Orchestrator Lambda ───

data "archive_file" "orchestrator_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/orchestrator"
  output_path = "${path.module}/../lambda/orchestrator.zip"
}


# ─── Orchestrator Lambda ───

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${var.project_name}-orchestrator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  filename         = data.archive_file.orchestrator_lambda_zip.output_path
  source_code_hash = data.archive_file.orchestrator_lambda_zip.output_base64sha256

  environment {
    variables = {
      ECS_CLUSTER     = aws_ecs_cluster.migration.arn
      TASK_DEFINITION = aws_ecs_task_definition.export_task.arn
      SUBNETS         = jsonencode(var.private_subnet_ids)
      SECURITY_GROUPS = jsonencode([aws_security_group.fargate_export.id])
      S3_BUCKET       = var.s3_bucket_name
      SNS_TOPIC_ARN   = aws_sns_topic.migration_alerts.arn
    }
  }

  tags = {
    Name = "${var.project_name}-orchestrator"
  }
}


# ─── Additional IAM for Orchestrator ───

resource "aws_iam_role_policy" "lambda_ecs_start" {
  name = "start-ecs-tasks"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecs:RunTask", "ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.migration.arn }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_sns_publish" {
  name = "sns-publish"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.migration_alerts.arn
      }
    ]
  })
}


# ──────────────────────────────────────────────
# S3 Event Triggers — the chain wiring
# ──────────────────────────────────────────────

resource "aws_lambda_permission" "s3_invoke_verify" {
  statement_id   = "AllowS3InvokeVerify"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.verify_backup.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.data_archive.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_lambda_permission" "s3_invoke_drop" {
  statement_id   = "AllowS3InvokeDrop"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.drop_partition.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.data_archive.arn
  source_account = data.aws_caller_identity.current.account_id
}

# manifest.json uploaded → verification Lambda
# verified.json uploaded → drop partition Lambda
resource "aws_s3_bucket_notification" "chain_triggers" {
  bucket = aws_s3_bucket.data_archive.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.verify_backup.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "metadata/"
    filter_suffix       = "manifest.json"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.drop_partition.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "metadata/"
    filter_suffix       = "verified.json"
  }

  depends_on = [
    aws_lambda_permission.s3_invoke_verify,
    aws_lambda_permission.s3_invoke_drop
  ]
}


# ─── EventBridge → Orchestrator Lambda ───
# SEPARATE schedule from the Step Functions one.
# Enable ONLY ONE at a time.

resource "aws_scheduler_schedule" "monthly_migration_lambda_chain" {
  name        = "${var.project_name}-monthly-trigger-lambda-chain"
  description = "Triggers Lambda-chain pipeline (alternative to Step Functions)"
  group_name  = "default"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = "DISABLED"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.orchestrator.arn
    role_arn = aws_iam_role.eventbridge_scheduler_role.arn

    input = jsonencode({
      trigger_source = "eventbridge-scheduler"
      action         = "migrate_previous_month"
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}

resource "aws_lambda_permission" "eventbridge_invoke_orchestrator" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestrator.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.monthly_migration_lambda_chain.arn
}

resource "aws_iam_role_policy" "eventbridge_invoke_lambda" {
  name = "invoke-orchestrator-lambda"
  role = aws_iam_role.eventbridge_scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.orchestrator.arn
      }
    ]
  })
}
