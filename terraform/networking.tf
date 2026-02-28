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
