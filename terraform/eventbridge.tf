# ──────────────────────────────────────────────
# EventBridge Scheduler — Triggers Orchestrator Lambda
# ──────────────────────────────────────────────
# Fires on the 1st of each month at midnight IST.
# Triggers the Orchestrator Lambda which starts the ECS task.
# Starts DISABLED — enable after testing.
# ──────────────────────────────────────────────

# ─── IAM Role for EventBridge ───

resource "aws_iam_role" "eventbridge_scheduler_role" {
  name = "${var.project_name}-eventbridge-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_orchestrator" {
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


# ─── The Schedule ───

resource "aws_scheduler_schedule" "monthly_migration" {
  name        = "${var.project_name}-monthly-trigger"
  description = "Fires on the 1st of each month — orchestrator launches one ECS task per daily partition in the previous month"
  group_name  = "default"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

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

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}

resource "aws_lambda_permission" "eventbridge_invoke_orchestrator" {
  statement_id   = "AllowEventBridgeInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.orchestrator.function_name
  principal      = "scheduler.amazonaws.com"
  source_arn     = aws_scheduler_schedule.monthly_migration.arn
}


# ─── Dead Letter Queue ───

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq"
  message_retention_seconds = 1209600 # 14 days
}


# ─── Data source ───

data "aws_caller_identity" "current" {}
