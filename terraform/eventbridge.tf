# ──────────────────────────────────────────────
# EventBridge Scheduler
# ──────────────────────────────────────────────
# This is the entry point of the entire migration pipeline.
#
# WHAT IT DOES:
#   - Fires on the 1st of each month at midnight IST
#   - Triggers the Step Functions state machine
#   - Passes a JSON payload with the target year/month
#
# WHAT IT DOES NOT DO:
#   - It does NOT run the migration itself
#   - It does NOT decide which month to migrate (Step Functions does that)
#
# The scheduler starts DISABLED. You enable it after
# the full pipeline is tested end-to-end.
# ──────────────────────────────────────────────


# ─── IAM Role for EventBridge Scheduler ───
# EventBridge needs permission to start the Step Functions
# state machine. This role grants exactly that — nothing more.

resource "aws_iam_role" "eventbridge_scheduler_role" {
  name = "${var.project_name}-eventbridge-scheduler-role"

  # Trust policy: allows EventBridge Scheduler to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-eventbridge-scheduler-role"
  }
}

# Permission policy: allow starting the Step Functions state machine
resource "aws_iam_role_policy" "eventbridge_start_sfn" {
  name = "start-step-functions"
  role = aws_iam_role.eventbridge_scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "states:StartExecution"
        # This references the Step Functions state machine we'll create next.
        # For now it uses a placeholder. We'll update this when we build Step Functions.
        Resource = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.project_name}-pipeline"
      }
    ]
  })
}


# ─── The Scheduler Itself ───

resource "aws_scheduler_schedule" "monthly_migration" {
  name        = "${var.project_name}-monthly-trigger"
  description = "Triggers RDS to S3 migration pipeline on the 1st of each month at midnight IST"
  group_name  = "default"

  # Schedule configuration
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  # DISABLED by default — flip to ENABLED after full pipeline is tested
  state = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    # IMPORTANT: OFF means "fire at exactly the scheduled time"
    # Use "FLEXIBLE" with max_window if you want a window (e.g., for cost savings)
    mode = "OFF"
  }

  target {
    # This will point to Step Functions once we create it.
    # The ARN follows a predictable pattern so we can reference it now.
    arn      = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.project_name}-pipeline"
    role_arn = aws_iam_role.eventbridge_scheduler_role.arn

    # ─── Payload ───
    # This JSON is what Step Functions receives when triggered.
    # It tells the pipeline WHICH month to migrate.
    #
    # The logic: when the scheduler fires on March 1st, we want
    # to migrate February's data. So we pass "migrate the previous month".
    #
    # We use a STATIC payload here. The Step Functions state machine
    # will compute the actual target month at runtime using its own
    # logic (current date minus 1 month). This is safer than having
    # EventBridge compute dates.
    input = jsonencode({
      trigger_source = "eventbridge-scheduler"
      action         = "migrate_previous_month"
      # Step Functions will resolve the actual year/month at runtime.
      # For manual/backfill runs, you override this by starting the
      # state machine directly with: {"year": "2025", "month": "02"}
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600  # retry for up to 1 hour
      maximum_retry_attempts       = 3
    }

    dead_letter_config {
      # If all retries fail, the event goes here so we can investigate.
      # We'll create this SQS queue in the next step.
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}


# ─── Dead Letter Queue ───
# If the scheduler fails to trigger Step Functions after all retries,
# the failed event is sent here. We monitor this queue for alerts.

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name = "${var.project_name}-scheduler-dlq"
  }
}


# ─── Data source to get current AWS account ID ───

data "aws_caller_identity" "current" {}
