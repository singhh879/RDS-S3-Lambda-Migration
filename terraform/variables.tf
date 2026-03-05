# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project identifier used in resource naming"
  type        = string
  default     = "rds-to-s3-migration"
}

# ─── EventBridge ───

variable "schedule_expression" {
  description = "Cron expression for the monthly trigger"
  type        = string
  default     = "cron(0 0 1 * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone"
  type        = string
  default     = "Asia/Kolkata"
}

variable "schedule_enabled" {
  description = "Whether the scheduler is active"
  type        = bool
  default     = false
}

# ─── S3 ───

variable "s3_bucket_name" {
  description = "S3 bucket for dump files"
  type        = string
  default     = "marsquant-market-data-archive"
}

# ─── RDS ───

variable "rds_endpoint" {
  description = "RDS instance endpoint"
  type        = string
}

variable "rds_port" {
  description = "RDS port"
  type        = number
  default     = 5432
}

variable "rds_database" {
  description = "Database name"
  type        = string
}

variable "rds_username" {
  description = "Database username"
  type        = string
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN for DB password"
  type        = string
}

# ─── Networking ───

variable "vpc_id" {
  description = "VPC ID where RDS lives"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (same VPC as RDS)"
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "RDS security group ID"
  type        = string
}

# ─── Alerts ───

variable "alert_email" {
  description = "Email for pipeline notifications"
  type        = string
}

# ─── Lambda Layer ───

variable "psycopg2_layer_arn" {
  description = "ARN of psycopg2 Lambda layer"
  type        = string
}
