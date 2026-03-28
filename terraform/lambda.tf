# ──────────────────────────────────────────────
# Lambda Functions + SNS + S3 Event Chain
# ──────────────────────────────────────────────
# Three Lambdas:
#   1. Orchestrator — starts ECS Fargate task
#   2. Verify — checks backup integrity (triggered by S3 event)
#   3. Drop Partition — drops RDS partition (triggered by S3 event)
#
# Chain: Orchestrator → ECS → manifest.json → Verify → verified.json → Drop
# ──────────────────────────────────────────────


# ─── SNS Topic for Alerts ───

resource "aws_sns_topic" "migration_alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.migration_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}


# ─── Package Lambda Code ───

data "archive_file" "orchestrator_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/orchestrator"
  output_path = "${path.module}/../lambda/orchestrator.zip"
}

data "archive_file" "verify_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/verify"
  output_path = "${path.module}/../lambda/verify.zip"
}

data "archive_file" "drop_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/drop_partition"
  output_path = "${path.module}/../lambda/drop_partition.zip"
}


# ─── Shared IAM Role ───

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Basic execution + VPC access
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# S3 read/write (verify reads manifest, writes verified.json; drop reads verified.json)
resource "aws_iam_role_policy" "lambda_s3" {
  name = "s3-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:HeadObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.data_archive.arn,
        "${aws_s3_bucket.data_archive.arn}/*"
      ]
    }]
  })
}

# Secrets Manager (DB password)
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.db_secret_arn
    }]
  })
}

# SNS publish (all Lambdas send notifications)
resource "aws_iam_role_policy" "lambda_sns" {
  name = "sns-publish"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.migration_alerts.arn
    }]
  })
}

# ECS access (orchestrator starts tasks)
resource "aws_iam_role_policy" "lambda_ecs" {
  name = "ecs-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:DescribeTasks"]
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


# ─── Lambda Security Group ───

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda"
  description = "Security group for all Lambda functions"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "lambda_to_rds" {
  type                     = "ingress"
  from_port                = var.rds_port
  to_port                  = var.rds_port
  protocol                 = "tcp"
  description              = "Allow Lambda to connect to RDS"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.lambda.id
}


# ─── CloudWatch Log Groups ───

resource "aws_cloudwatch_log_group" "orchestrator_logs" {
  name              = "/aws/lambda/${var.project_name}-orchestrator"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "verify_logs" {
  name              = "/aws/lambda/${var.project_name}-verify-backup"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "drop_logs" {
  name              = "/aws/lambda/${var.project_name}-drop-partition"
  retention_in_days = 30
}


# ═══════════════════════════════════════════
# Lambda 1: Orchestrator
# ═══════════════════════════════════════════

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${var.project_name}-orchestrator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 420   # 7 min: handles 31 days x 10s stagger (310s) + overhead
  memory_size      = 256
  architectures    = ["arm64"]

  filename         = data.archive_file.orchestrator_zip.output_path
  source_code_hash = data.archive_file.orchestrator_zip.output_base64sha256

  environment {
    variables = {
      ECS_CLUSTER     = aws_ecs_cluster.migration.arn
      TASK_DEFINITION = aws_ecs_task_definition.export_task.arn
      SUBNETS         = jsonencode(var.private_subnet_ids)
      SECURITY_GROUPS = jsonencode([aws_security_group.fargate_export.id])
      SNS_TOPIC_ARN   = aws_sns_topic.migration_alerts.arn
      CONTAINER_NAME  = "export"
    }
  }

  depends_on = [aws_cloudwatch_log_group.orchestrator_logs]
}


# ═══════════════════════════════════════════
# Lambda 2: Verification
# ═══════════════════════════════════════════

resource "aws_lambda_function" "verify_backup" {
  function_name    = "${var.project_name}-verify-backup"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256
  architectures    = ["arm64"]

  filename         = data.archive_file.verify_zip.output_path
  source_code_hash = data.archive_file.verify_zip.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST       = var.rds_endpoint
      DB_PORT       = tostring(var.rds_port)
      DB_NAME       = var.rds_database
      DB_USER       = var.rds_username
      DB_SECRET_ARN = var.db_secret_arn
      SNS_TOPIC_ARN = aws_sns_topic.migration_alerts.arn
    }
  }

  layers = [var.psycopg2_layer_arn]

  depends_on = [aws_cloudwatch_log_group.verify_logs]
}


# ═══════════════════════════════════════════
# Lambda 3: Drop Partition
# ═══════════════════════════════════════════

resource "aws_lambda_function" "drop_partition" {
  function_name    = "${var.project_name}-drop-partition"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  architectures    = ["arm64"]

  filename         = data.archive_file.drop_zip.output_path
  source_code_hash = data.archive_file.drop_zip.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST       = var.rds_endpoint
      DB_PORT       = tostring(var.rds_port)
      DB_NAME       = var.rds_database
      DB_USER       = var.rds_username
      DB_SECRET_ARN = var.db_secret_arn
      S3_BUCKET     = var.s3_bucket_name
      SNS_TOPIC_ARN = aws_sns_topic.migration_alerts.arn
    }
  }

  layers = [var.psycopg2_layer_arn]

  depends_on = [aws_cloudwatch_log_group.drop_logs]
}


# ═══════════════════════════════════════════
# S3 Event Chain — The Wiring
# ═══════════════════════════════════════════
# manifest.json upload → triggers Verify Lambda
# verified.json upload → triggers Drop Partition Lambda

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
