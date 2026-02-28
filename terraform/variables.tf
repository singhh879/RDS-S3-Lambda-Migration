# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────
# All configurable values live here. This means
# you never hardcode values in resource definitions.
# To change the schedule, region, or project name,
# you edit terraform.tfvars (not resource files).
# ──────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where all resources are created"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project identifier used in resource naming"
  type        = string
  default     = "rds-to-s3-migration"
}

# ─── EventBridge Schedule ───

variable "schedule_expression" {
  description = "Cron expression for the monthly migration trigger (UTC)"
  type        = string
  # 1st of each month at midnight IST = 18:30 UTC on the last day of previous month
  # IST is UTC+5:30, so midnight IST = 18:30 UTC previous day
  # However, EventBridge Scheduler supports timezone natively, so we use IST directly
  default = "cron(0 0 1 * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone for the schedule"
  type        = string
  default     = "Asia/Kolkata"
}

variable "schedule_enabled" {
  description = "Whether the scheduler is active. Set to false during development."
  type        = bool
  default     = false # IMPORTANT: starts disabled, enable when pipeline is tested
}

# ─── S3 ───

variable "s3_bucket_name" {
  description = "S3 bucket for storing migrated data"
  type        = string
  default     = "marsquant-market-data-archive"
}

# ─── RDS Connection ───

variable "rds_endpoint" {
  description = "RDS instance endpoint (host). Get this from AWS console → RDS → your instance."
  type        = string
}

variable "rds_port" {
  description = "RDS port (usually 5432 for PostgreSQL)"
  type        = number
  default     = 5432
}

variable "rds_database" {
  description = "Database name inside RDS"
  type        = string
}

variable "rds_username" {
  description = "Database username"
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the DB password. Create this manually in AWS console → Secrets Manager before running Terraform."
  type        = string
}

# ─── Networking ───
# The Fargate task needs to run inside the same VPC as RDS
# so it can reach the database on port 5432.

variable "vpc_id" {
  description = "VPC ID where RDS lives. Find in AWS console → VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the Fargate task. Must be in the same VPC as RDS."
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "Security group ID of the RDS instance. The Fargate task needs access to this."
  type        = string
}

# ─── Alerts ───

variable "alert_email" {
  description = "Email address for pipeline success/failure notifications"
  type        = string
}

# ─── Lambda Layer ───

variable "psycopg2_layer_arn" {
  description = "ARN of a Lambda layer providing psycopg2. Build your own or use a public one."
  type        = string
  default     = ""
}


