# ──────────────────────────────────────────────
# Provider & Backend Configuration
# ──────────────────────────────────────────────
# This is the entry point of the Terraform project.
# It tells Terraform which cloud provider to use (AWS)
# and where to store its state file.
#
# STATE FILE: Terraform tracks what resources it has
# created in a "state file". By default this is local
# (terraform.tfstate on your machine). For team use,
# you'd move this to S3 — we'll do that later.
# ──────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ─── For now: local state ───
  # When you're ready for team collaboration, uncomment
  # the S3 backend below and run `terraform init -migrate-state`
  #
  # backend "s3" {
  #   bucket         = "marsquant-terraform-state"
  #   key            = "rds-to-s3-migration/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "rds-to-s3-migration"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
