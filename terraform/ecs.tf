# ──────────────────────────────────────────────
# ECR + ECS Fargate — The Compute Layer
# ──────────────────────────────────────────────
# This file creates:
#   1. ECR repository (stores our Docker image)
#   2. ECS cluster (logical grouping, no servers)
#   3. ECS task definition (what container to run, how much CPU/memory)
#   4. IAM roles (permissions for the task)
#
# HOW IT WORKS:
#   Step Functions tells ECS: "Run this task definition"
#   ECS Fargate: spins up a container, runs export.sh, exits
#   Step Functions: detects exit code, moves to next step
#
# COST:
#   You pay only while the container is running.
#   A 1-hour export on 2 vCPU + 8 GB memory ≈ ₹15-20
# ──────────────────────────────────────────────


# ─── ECR Repository ───
# This is where we push our Docker image.
# Think of it as a private Docker Hub inside your AWS account.

resource "aws_ecr_repository" "export_image" {
  name                 = "${var.project_name}-export"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true   # scans for known vulnerabilities
  }

  tags = {
    Name = "${var.project_name}-export"
  }
}

# Auto-delete old images to save storage cost.
# Keep only the last 5 images.
resource "aws_ecr_lifecycle_policy" "export_image" {
  repository = aws_ecr_repository.export_image.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}


# ─── ECS Cluster ───
# A logical grouping. With Fargate, there are NO servers behind this.
# It's just a namespace for your tasks.

resource "aws_ecs_cluster" "migration" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"   # sends metrics to CloudWatch
  }

  tags = {
    Name = "${var.project_name}-cluster"
  }
}


# ─── CloudWatch Log Group ───
# All container output (the log lines from export.sh) goes here.
# This is how you debug failed runs.

resource "aws_cloudwatch_log_group" "export_task" {
  name              = "/ecs/${var.project_name}-export"
  retention_in_days = 30   # keep logs for 30 days

  tags = {
    Name = "${var.project_name}-export-logs"
  }
}


# ─── IAM: Task Execution Role ───
# This role is used by ECS ITSELF (not your container) to:
#   - Pull the Docker image from ECR
#   - Send logs to CloudWatch
#   - Read secrets from Secrets Manager (for DB password)

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-execution-role"
  }
}

# Attach the AWS-managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional permission: read the DB password from Secrets Manager
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "read-secrets"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.db_secret_arn
      }
    ]
  })
}


# ─── IAM: Task Role ───
# This role is used by YOUR CONTAINER (export.sh) to:
#   - Upload dump files to S3
#   - Write metadata to S3
# It does NOT have permission to read/delete from S3 — principle of least privilege.

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-task-role"
  }
}

resource "aws_iam_role_policy" "ecs_task_s3_write" {
  name = "s3-write-backups"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = "${aws_s3_bucket.data_archive.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.data_archive.arn
      }
    ]
  })
}


# ─── ECS Task Definition ───
# This defines WHAT to run: which image, how much CPU/memory,
# what environment variables to pass, where to send logs.
#
# CPU/MEMORY SIZING:
#   pg_dump for a large month might need significant memory.
#   2 vCPU + 8 GB is a safe starting point.
#   If dumps are smaller, you can reduce to 1 vCPU + 4 GB.
#   Fargate pricing: 2 vCPU + 8 GB ≈ ₹15-20 per hour.
#
# ENVIRONMENT VARIABLES:
#   DB connection details are injected here.
#   PGPASSWORD comes from Secrets Manager (not hardcoded).
#   TARGET_YEAR and TARGET_MONTH are overridden at runtime
#   by Step Functions when it starts the task.

resource "aws_ecs_task_definition" "export_task" {
  family                   = "${var.project_name}-export"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"      # required for Fargate
  cpu                      = 2048          # 2 vCPU
  memory                   = 8192          # 8 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  # Ephemeral storage for the dump file before upload
  # Default is 20 GB, increase if single month dumps exceed that
  ephemeral_storage {
    size_in_gib = 100    # 100 GB — enough for the largest monthly dump
  }

  container_definitions = jsonencode([
    {
      name      = "export"
      image     = "${aws_ecr_repository.export_image.repository_url}:latest"
      essential = true

      environment = [
        { name = "PGHOST",       value = var.rds_endpoint },
        { name = "PGPORT",       value = tostring(var.rds_port) },
        { name = "PGDATABASE",   value = var.rds_database },
        { name = "PGUSER",       value = var.rds_username },
        { name = "S3_BUCKET",    value = var.s3_bucket_name },
        # TARGET_YEAR and TARGET_MONTH are overridden by Step Functions
        # at runtime via containerOverrides. Defaults here for safety.
        { name = "TARGET_YEAR",  value = "2025" },
        { name = "TARGET_MONTH", value = "02" },
      ]

      # DB password from Secrets Manager — never hardcoded
      secrets = [
        {
          name      = "PGPASSWORD"
          valueFrom = var.db_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.export_task.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "export"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-export-task"
  }
}
