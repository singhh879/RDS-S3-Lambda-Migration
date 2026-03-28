# ──────────────────────────────────────────────
# Networking — Security Group for Fargate Task
# ──────────────────────────────────────────────
# The Fargate task needs to:
#   1. Connect to RDS on port 5432 (PostgreSQL)
#   2. Connect to S3 (via VPC endpoint or internet)
#   3. Connect to ECR to pull the Docker image
#
# We create a security group that allows outbound traffic
# and add a rule to the RDS security group to accept traffic
# from our Fargate task.
# ──────────────────────────────────────────────

resource "aws_security_group" "fargate_export" {
  name        = "${var.project_name}-fargate-export"
  description = "Security group for the pg_dump Fargate task"
  vpc_id      = var.vpc_id

  # Allow ALL outbound traffic
  # (needed for: RDS connection, S3 upload, ECR image pull, CloudWatch logs)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  # No inbound rules needed — the task only makes outbound connections

  tags = {
    Name = "${var.project_name}-fargate-export"
  }
}

# Allow the Fargate task to connect to RDS
# This adds a rule to your EXISTING RDS security group
resource "aws_security_group_rule" "fargate_to_rds" {
  type                     = "ingress"
  from_port                = var.rds_port
  to_port                  = var.rds_port
  protocol                 = "tcp"
  description              = "Allow Fargate export task to connect to RDS"
  security_group_id        = var.rds_security_group_id          # the RDS SG
  source_security_group_id = aws_security_group.fargate_export.id  # our Fargate SG
}

# ──────────────────────────────────────────────
# VPC Endpoints — private connectivity without NAT gateway
# ──────────────────────────────────────────────
# The private subnets have no NAT gateway. Without VPC endpoints,
# Fargate can't pull from ECR and Lambdas can't reach Secrets Manager.
#
# Already existing (created outside Terraform, not managed here):
#   - ecr.dkr  (image layer pulls)
#   - s3       (dump upload / manifest read)
#
# Adding the missing ones below:
#   - ecr.api        (ECR auth token — required alongside ecr.dkr for Fargate)
#   - secretsmanager (DB password fetch in verify + drop Lambdas)
#   - logs           (CloudWatch logs from Fargate tasks)
# ──────────────────────────────────────────────

# Security group for VPC endpoints — allows HTTPS from Lambda and Fargate SGs
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints"
  description = "Allow HTTPS from Lambda and Fargate to VPC endpoints"
  vpc_id      = var.vpc_id

  # Allow HTTPS from all VPC resources (10.8.0.0/16) — private DNS on these
  # endpoints affects ALL services in the VPC, not just our Lambdas/Fargate.
  # Using VPC CIDR instead of specific SGs to avoid blocking other pipelines.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.8.0.0/16"]
    description = "HTTPS from entire VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vpc-endpoints" }
}

# One subnet per AZ (endpoints require unique AZs):
#   ap-south-1a → subnet-0ebafcb795590843a  (matches existing ecr.dkr endpoint)
#   ap-south-1b → subnet-041854aa2a8ece26d  (matches existing s3 endpoint)
locals {
  endpoint_subnet_ids = ["subnet-0ebafcb795590843a", "subnet-041854aa2a8ece26d"]
}

# ECR API — auth token endpoint (required alongside ecr.dkr for image pulls)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.project_name}-ecr-api" }
}

# Secrets Manager — DB password for verify + drop Lambdas
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.project_name}-secretsmanager" }
}

# CloudWatch Logs — Fargate task logs
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.project_name}-logs" }
}

# SNS — Lambda notifications (all 3 Lambdas publish alerts via SNS)
resource "aws_vpc_endpoint" "sns" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.project_name}-sns" }
}
