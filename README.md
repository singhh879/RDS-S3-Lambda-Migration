# RDS to S3 Migration Pipeline

Automated pipeline that exports daily RDS PostgreSQL partitions to S3, verifies the backup, then drops the old partition from RDS. Runs on the 1st of every month via EventBridge, or can be triggered manually.

---

## How It Works

```
EventBridge (1st of month)
        ↓
Orchestrator Lambda
  → launches 1 ECS task per day of the previous month
        ↓
ECS Fargate (per day)
  → pg_dump → upload to S3 → write manifest.json
        ↓  (S3 event)
Verify Lambda
  → 5 integrity checks → write verified.json
        ↓  (S3 event)
Drop Partition Lambda
  → reads verified.json → DETACH + DROP partition from RDS
```

Data is **never deleted** unless all verification checks pass.

---

## Repo Structure

```
├── lambda/
│   ├── orchestrator/handler.py      # Starts migration, launches ECS tasks
│   ├── verify/handler.py            # Validates backup integrity
│   └── drop_partition/handler.py    # Drops partition after verification
├── docker/
│   ├── export.sh                    # Runs pg_dump inside ECS container
│   └── Dockerfile                   # ECS container definition
├── terraform/
│   ├── terraform.tfvars.example     # Copy this → terraform.tfvars
│   └── *.tf                         # All AWS infrastructure
├── test/                            # Full local test suite
├── scripts/                         # Utility SQL and Python scripts
└── docs/                            # Progress and testing docs
```

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0
- Docker Desktop
- Python 3.12
- An S3 bucket name, RDS endpoint, VPC ID, and subnet IDs ready

---

## Setup (Fresh Deploy)

### 1. Clone the repo

```bash
git clone https://github.com/singhh879/RDS-S3-Lambda-Migration.git
cd RDS-S3-Lambda-Migration
```

### 2. Create your config

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and fill in your values:

| Variable | Description | Example |
|---|---|---|
| `rds_endpoint` | RDS instance endpoint | `mydb.xxxx.ap-south-1.rds.amazonaws.com` |
| `rds_database` | Database name | `datafeeddatabase` |
| `rds_username` | DB username | `marsquantMasterUser` |
| `db_secret_arn` | Secrets Manager ARN for DB password | `arn:aws:secretsmanager:...` |
| `vpc_id` | VPC where RDS lives | `vpc-xxxxxxxxx` |
| `private_subnet_ids` | Private subnet IDs (same VPC as RDS) | `["subnet-xxx", "subnet-yyy"]` |
| `rds_security_group_id` | RDS security group ID | `sg-xxxxxxxxx` |
| `s3_bucket_name` | S3 bucket for backups | `my-market-data-archive` |
| `alert_email` | Email for notifications | `alerts@yourcompany.com` |
| `psycopg2_layer_arn` | ARN of psycopg2 Lambda layer (see step 3) | `arn:aws:lambda:...:layer:psycopg2:1` |

> `terraform.tfvars` is gitignored — your credentials will never be committed.

### 3. Build and upload the psycopg2 Lambda layer

The Verify and Drop Partition Lambdas need psycopg2 to connect to PostgreSQL.

```bash
mkdir -p python
pip install psycopg2-binary --platform manylinux2014_x86_64 \
  --python-version 3.12 --only-binary=:all: -t python/
zip -r psycopg2-layer.zip python/

aws lambda publish-layer-version \
  --layer-name psycopg2-python312 \
  --zip-file fileb://psycopg2-layer.zip \
  --compatible-runtimes python3.12 \
  --compatible-architectures x86_64 \
  --region ap-south-1
```

Copy the `LayerVersionArn` from the output and paste it as `psycopg2_layer_arn` in your `terraform.tfvars`.

### 4. Deploy infrastructure

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

This creates ~30 AWS resources: Lambda functions, ECS cluster, ECR repo, S3 bucket, EventBridge schedule, VPC endpoints, IAM roles, and SNS topic.

When prompted, check your email and confirm the SNS subscription.

### 5. Build and push the Docker image

Get your AWS account ID:
```bash
aws sts get-caller-identity --query Account --output text
```

Then build and push:
```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin \
    <YOUR_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com

docker build -t rds-to-s3-migration-export docker/

docker tag rds-to-s3-migration-export:latest \
  <YOUR_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/rds-to-s3-migration-export:latest

docker push \
  <YOUR_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/rds-to-s3-migration-export:latest
```

---

## Running the Migration

### Automatic (recommended)

Enable the monthly EventBridge schedule:

```bash
terraform apply -var='schedule_enabled=true'
```

It will fire on the 1st of every month at midnight IST and automatically migrate the previous month.

### Manual — full month

Go to **AWS Lambda → `rds-to-s3-migration-orchestrator`** → **Test**, and use:

```json
{
  "action": "migrate_month",
  "year": "2025",
  "month": "09"
}
```

### Manual — single day

```json
{
  "year": "2025",
  "month": "09",
  "day": "01"
}
```

---

## Monitoring

- **Email** — SNS sends alerts at each stage (start, verified, complete, or failure)
- **CloudWatch Logs:**
  - `/aws/lambda/rds-to-s3-migration-orchestrator`
  - `/ecs/rds-to-s3-migration-export`
  - `/aws/lambda/rds-to-s3-migration-verify`
  - `/aws/lambda/rds-to-s3-migration-drop-partition`
- **S3** — check for `manifest.json` and `verified.json` under `metadata/YYYY/MM/DD/`

---

## Testing Locally

Runs the full pipeline against a local Docker Postgres container.

```bash
# 1. Start test database
docker compose -f test/docker-compose.yml up -d

# 2. Load schema (creates partitions with 15,000 test rows)
docker exec -i marsquant-test-postgres psql \
  -U marsquantMasterUser -d datafeeddatabase < test/setup_test_db.sql

# 3. Set up Python environment
python3 -m venv test/.venv && source test/.venv/bin/activate
pip install psycopg2-binary boto3 moto pytest

# 4. Run full chain
bash test/test_full_chain.sh
```

Expected: `All tests passed. (16/16)`

```bash
# Teardown
bash test/cleanup.sh
```

---

## S3 Layout

```
s3://<your-bucket>/
├── backups/
│   └── YYYY/MM/DD/
│       └── dump_YYYYMMDD.sql.gz
└── metadata/
    └── YYYY/MM/DD/
        ├── manifest.json     ← written by ECS, triggers Verify Lambda
        └── verified.json     ← written by Verify Lambda, triggers Drop Lambda
```

### Lifecycle (automatic)

| Age | Storage Class | Cost |
|---|---|---|
| 0 – 90 days | S3 Standard | Full price |
| 90 – 180 days | S3 Standard-IA | ~50% cheaper |
| 180+ days | Glacier Instant Retrieval | ~75% cheaper |
