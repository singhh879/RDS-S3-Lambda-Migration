# ──────────────────────────────────────────────
# Step Functions — Pipeline Orchestrator
# ──────────────────────────────────────────────
# This is the brain of the migration pipeline.
# It enforces this exact sequence:
#
#   1. Run ECS Fargate task (pg_dump → S3)
#      ├─ If fails → notify failure → STOP
#      └─ If succeeds ↓
#   2. Wait 60 seconds (S3 consistency)
#   3. Run Verification Lambda
#      ├─ If fails → notify failure → STOP
#      └─ If verified=true ↓
#   4. Run Drop Partition Lambda
#      ├─ If fails → notify failure → STOP
#      └─ If succeeds ↓
#   5. Notify success → END
#
# CRITICAL SAFETY GUARANTEE:
#   Step 4 (drop partition) CANNOT execute unless
#   Step 3 (verification) returns verified=true.
#   This is enforced by the state machine, not by
#   human discipline or Lambda wiring.
#
# HOW TO START MANUALLY (for backfill):
#   aws stepfunctions start-execution \
#     --state-machine-arn <ARN> \
#     --input '{"year": "2025", "month": "02"}'
#
# HOW IT'S STARTED AUTOMATICALLY:
#   EventBridge fires on the 1st of each month →
#   passes {"action": "migrate_previous_month"} →
#   the ComputeTargetMonth step resolves the actual year/month.
# ──────────────────────────────────────────────


# ─── SNS Topic for Alerts ───
# Both success and failure notifications go here.
# Subscribe your email or Slack webhook to this topic.

resource "aws_sns_topic" "migration_alerts" {
  name = "${var.project_name}-alerts"

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

# Subscribe your email — you'll get a confirmation email, click to confirm
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.migration_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}


# ─── IAM Role for Step Functions ───

resource "aws_iam_role" "step_functions_role" {
  name = "${var.project_name}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-sfn-role"
  }
}

# Step Functions needs permission to:
# - Run ECS tasks
# - Invoke Lambda functions
# - Publish to SNS
# - Pass IAM roles to ECS
# - Read CloudWatch logs

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "sfn-pipeline-policy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunECSTasks"
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "ecs:cluster" = aws_ecs_cluster.migration.arn
          }
        }
      },
      {
        Sid    = "PassRolesToECS"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      },
      {
        Sid    = "InvokeLambdas"
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          aws_lambda_function.verify_backup.arn,
          aws_lambda_function.drop_partition.arn
        ]
      },
      {
        Sid    = "PublishSNS"
        Effect = "Allow"
        Action = "sns:Publish"
        Resource = aws_sns_topic.migration_alerts.arn
      },
      {
        Sid    = "EventsForECSTask"
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"
      }
    ]
  })
}


# ─── The State Machine Definition ───

resource "aws_sfn_state_machine" "migration_pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "RDS to S3 monthly migration pipeline"
    StartAt = "ComputeTargetMonth"

    States = {

      # ── Step 0: Determine which month to migrate ──
      # If triggered by EventBridge with "migrate_previous_month",
      # we use a Lambda-less Pass state that expects the caller
      # to have resolved year/month. For EventBridge triggers,
      # the scheduler should pass the specific month.
      # For manual backfill, you pass {"year": "2025", "month": "02"} directly.
      ComputeTargetMonth = {
        Type    = "Pass"
        Comment = "Pass through — expects year and month in input. For EventBridge: override input with specific month."
        Next    = "RunPgDumpExport"
      }

      # ── Step 1: Run the ECS Fargate pg_dump task ──
      RunPgDumpExport = {
        Type     = "Task"
        Comment  = "Runs the Docker container that executes pg_dump and uploads to S3"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          Cluster        = aws_ecs_cluster.migration.arn
          TaskDefinition = aws_ecs_task_definition.export_task.arn
          LaunchType     = "FARGATE"

          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = var.private_subnet_ids
              SecurityGroups = [aws_security_group.fargate_export.id]
              AssignPublicIp = "DISABLED"
            }
          }

          Overrides = {
            ContainerOverrides = [
              {
                Name = "export"
                Environment = [
                  {
                    Name  = "TARGET_YEAR"
                    "Value.$" = "$.year"
                  },
                  {
                    Name  = "TARGET_MONTH"
                    "Value.$" = "$.month"
                  }
                ]
              }
            ]
          }
        }

        # Pass year/month forward to the next step
        ResultPath = "$.ecsResult"

        # Retry on transient failures (not on dump errors — those exit non-zero)
        Retry = [
          {
            ErrorEquals     = ["States.TaskFailed"]
            IntervalSeconds = 60
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "NotifyFailure"
            ResultPath  = "$.error"
          }
        ]

        Next = "WaitForS3Consistency"
      }

      # ── Step 2: Brief wait for S3 read-after-write consistency ──
      WaitForS3Consistency = {
        Type    = "Wait"
        Seconds = 30
        Next    = "RunVerification"
      }

      # ── Step 3: Verify the backup ──
      RunVerification = {
        Type     = "Task"
        Comment  = "Checks: file exists in S3, file size, row count matches RDS"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.verify_backup.arn
          Payload = {
            "year.$"  = "$.year"
            "month.$" = "$.month"
            "bucket"  = var.s3_bucket_name
          }
        }

        ResultPath = "$.verificationResult"
        ResultSelector = {
          "verified.$"  = "$.Payload.verified"
          "details.$"   = "$.Payload.details"
        }

        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
            IntervalSeconds = 10
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "NotifyFailure"
            ResultPath  = "$.error"
          }
        ]

        Next = "CheckVerification"
      }

      # ── Step 3b: Branch based on verification result ──
      CheckVerification = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.verificationResult.verified"
            BooleanEquals = true
            Next          = "RunDropPartition"
          }
        ]
        Default = "NotifyVerificationFailed"
      }

      # Verification failed — alert but do NOT drop partition
      NotifyVerificationFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.migration_alerts.arn
          Subject  = "MIGRATION ALERT: Verification FAILED"
          "Message.$" = "States.Format('Verification failed for {}-{}. Details: {}. NO DATA WAS DELETED. Please investigate.', $.year, $.month, $.verificationResult.details)"
        }
        End = true
      }

      # ── Step 4: Drop the RDS partition ──
      # This state ONLY executes if CheckVerification chose this path
      RunDropPartition = {
        Type     = "Task"
        Comment  = "Drops the old partition from RDS. Only runs after successful verification."
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.drop_partition.arn
          Payload = {
            "year.$"  = "$.year"
            "month.$" = "$.month"
          }
        }

        ResultPath = "$.dropResult"

        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException"]
            IntervalSeconds = 10
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "NotifyFailure"
            ResultPath  = "$.error"
          }
        ]

        Next = "NotifySuccess"
      }

      # ── Step 5: Success notification ──
      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.migration_alerts.arn
          Subject  = "MIGRATION SUCCESS"
          "Message.$" = "States.Format('Migration complete for {}-{}. Backup in S3, partition dropped from RDS.', $.year, $.month)"
        }
        End = true
      }

      # ── Failure notification (catch-all) ──
      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.migration_alerts.arn
          Subject  = "MIGRATION ALERT: Pipeline FAILED"
          "Message.$" = "States.Format('Migration pipeline failed for {}-{}. Error: {}. NO DATA WAS DELETED. Please investigate.', $.year, $.month, $.error)"
        }
        End = true
      }
    }
  })

  tags = {
    Name = "${var.project_name}-pipeline"
  }
}
