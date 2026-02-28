# ──────────────────────────────────────────────
# Lambda Functions — Verification & Partition Drop
# ──────────────────────────────────────────────
# Two small Python functions:
#   1. verify_backup — checks S3 file + row count
#   2. drop_partition — drops RDS partition after verification
#
# Both use psycopg2 to connect to RDS. Since psycopg2
# needs compiled C libraries, we use an AWS-provided Lambda
# layer that includes it.
#
# COST: Essentially free. Each invocation takes <30 seconds.
# ──────────────────────────────────────────────


# ─── Lambda Layer for psycopg2 ───
# psycopg2 needs compiled binaries that aren't in the Lambda runtime.
# We use the aws-psycopg2 layer which provides it.
# You can also build your own layer, but this is faster.

# ─── Package the Lambda code into zip files ───

data "archive_file" "verify_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/verify"
  output_path = "${path.module}/../lambda/verify.zip"
}

data "archive_file" "drop_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/drop_partition"
  output_path = "${path.module}/../lambda/drop_partition.zip"
}


# ─── IAM Role for Lambda Functions ───
# Both Lambdas share a role. They need:
#   - CloudWatch Logs (for logging)
#   - S3 read (verification reads the manifest + checks file)
#   - RDS network access (via VPC)
#   - Secrets Manager (for DB password)

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

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

  tags = {
    Name = "${var.project_name}-lambda-role"
  }
}

# Basic Lambda execution + VPC access
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# S3 read access (for verification Lambda)
resource "aws_iam_role_policy" "lambda_s3_read" {
  name = "s3-read-backups"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:HeadObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_archive.arn,
          "${aws_s3_bucket.data_archive.arn}/*"
        ]
      }
    ]
  })
}

# Secrets Manager access (for DB password)
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.db_secret_arn
      }
    ]
  })
}


# ─── Security Group for Lambdas ───
# Lambdas run in VPC to reach RDS. They need a security group.

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda"
  description = "Security group for verification and drop partition Lambdas"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (RDS, S3, Secrets Manager)"
  }

  tags = {
    Name = "${var.project_name}-lambda"
  }
}

# Allow Lambda to connect to RDS
resource "aws_security_group_rule" "lambda_to_rds" {
  type                     = "ingress"
  from_port                = var.rds_port
  to_port                  = var.rds_port
  protocol                 = "tcp"
  description              = "Allow Lambda to connect to RDS"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.lambda.id
}


# ─── Verification Lambda ───

resource "aws_lambda_function" "verify_backup" {
  function_name    = "${var.project_name}-verify-backup"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120        # 2 minutes — enough for S3 check + RDS query
  memory_size      = 256

  filename         = data.archive_file.verify_lambda_zip.output_path
  source_code_hash = data.archive_file.verify_lambda_zip.output_base64sha256

  # Run in VPC so it can reach RDS
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
      DB_PASSWORD   = "PLACEHOLDER"
      SNS_TOPIC_ARN = aws_sns_topic.migration_alerts.arn
    }
  }

  # psycopg2 layer — provides the compiled PostgreSQL client library
  layers = [var.psycopg2_layer_arn]

  tags = {
    Name = "${var.project_name}-verify-backup"
  }
}


# ─── Drop Partition Lambda ───

resource "aws_lambda_function" "drop_partition" {
  function_name    = "${var.project_name}-drop-partition"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300        # 5 minutes — VACUUM can take a while
  memory_size      = 256

  filename         = data.archive_file.drop_lambda_zip.output_path
  source_code_hash = data.archive_file.drop_lambda_zip.output_base64sha256

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
      DB_PASSWORD   = "PLACEHOLDER"
      S3_BUCKET     = var.s3_bucket_name
      SNS_TOPIC_ARN = aws_sns_topic.migration_alerts.arn
    }
  }

  layers = [var.psycopg2_layer_arn]

  tags = {
    Name = "${var.project_name}-drop-partition"
  }
}
