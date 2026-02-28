# RDS to S3 Migration — Terraform Infrastructure

## Project Structure

```
terraform/
├── main.tf              # Provider config, backend config
├── variables.tf         # All variable declarations
├── terraform.tfvars     # Actual values (edit this)
├── eventbridge.tf       # EventBridge Scheduler + IAM + DLQ
├── outputs.tf           # Values printed after apply
└── README.md            # You are here
```

## Prerequisites

1. **Install Terraform** (v1.5+):
   ```bash
   # macOS
   brew install terraform

   # Or download from: https://developer.hashicorp.com/terraform/install
   ```

2. **Configure AWS CLI** with credentials that have admin access:
   ```bash
   aws configure
   # Enter: AWS Access Key, Secret Key, Region: ap-south-1, Output: json
   ```

3. **Verify access:**
   ```bash
   aws sts get-caller-identity
   # Should return your account ID
   ```

## How to Deploy

```bash
cd terraform/

# Step 1: Initialize (downloads AWS provider plugin)
terraform init

# Step 2: Preview what will be created
terraform plan

# Step 3: Create the resources
terraform apply
# Type 'yes' when prompted

# Step 4: Verify
terraform output
```

## What Gets Created

| Resource | Purpose |
|----------|---------|
| EventBridge Schedule | Monthly trigger (1st, midnight IST) — starts DISABLED |
| IAM Role | Allows EventBridge to start Step Functions |
| SQS Dead Letter Queue | Catches failed trigger attempts |

## How to Enable the Scheduler

The scheduler starts **DISABLED** intentionally. Only enable after the full
pipeline (Step Functions + Fargate + Lambdas) is deployed and tested.

```bash
# Option 1: Change in terraform.tfvars
schedule_enabled = true
terraform apply

# Option 2: Quick enable via AWS CLI (doesn't update Terraform state)
aws scheduler update-schedule \
  --name rds-to-s3-migration-monthly-trigger \
  --state ENABLED \
  --schedule-expression "cron(0 0 1 * ? *)" \
  --schedule-expression-timezone "Asia/Kolkata" \
  --flexible-time-window '{"Mode": "OFF"}' \
  --target '...'
```

## How to Trigger a Manual/Backfill Run

Don't use the scheduler for backfill. Start Step Functions directly:

```bash
# Migrate a specific month
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:ap-south-1:ACCOUNT_ID:stateMachine:rds-to-s3-migration-pipeline \
  --input '{"year": "2025", "month": "02"}'
```

## Next Steps

After this is deployed, we build (in order):
1. **S3 bucket** with versioning + lifecycle rules
2. **ECS Fargate** task definition + ECR repo
3. **Step Functions** state machine
4. **Lambda functions** (verification + partition drop)
5. **Glue Catalog** for Athena
6. **SNS** for alerts
