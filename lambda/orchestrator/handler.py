"""
Orchestrator Lambda (Lambda-Chain Version)
──────────────────────────────────────────
This Lambda replaces Step Functions in the simpler pipeline.

WHAT IT DOES:
  1. Receives year/month from EventBridge (or manual invocation)
  2. Starts the ECS Fargate task with the correct environment variables
  3. Does NOT wait for the task — ECS completion triggers verification
     via S3 event notification on the manifest.json upload

FLOW:
  EventBridge (or manual)
      │
      ▼
  This Lambda (starts ECS task)
      │
      ▼
  ECS Fargate runs pg_dump → uploads dump + manifest.json to S3
      │
      ▼
  S3 PutObject event on metadata/YYYY/MM/manifest.json
      │
      ▼
  Verification Lambda (triggered by S3 event)
      │
      ├─ verified=false → SNS FAILURE alert → STOP
      │
      ▼ verified=true
  Drop Partition Lambda (invoked by Verification Lambda directly)
      │
      ▼
  SNS SUCCESS alert → END

MANUAL TRIGGER:
  aws lambda invoke \
    --function-name rds-to-s3-migration-orchestrator \
    --payload '{"year":"2025","month":"02"}' \
    /tmp/result.json
"""

import os
import json
import boto3
from datetime import datetime, timedelta

ecs_client = boto3.client("ecs")
sns_client = boto3.client("sns")

CLUSTER        = os.environ["ECS_CLUSTER"]
TASK_DEF       = os.environ["ECS_TASK_DEFINITION"]
SUBNETS        = json.loads(os.environ["SUBNETS"])
SECURITY_GROUP = os.environ["SECURITY_GROUP"]
SNS_TOPIC_ARN  = os.environ["SNS_TOPIC_ARN"]
CONTAINER_NAME = os.environ.get("CONTAINER_NAME", "export")


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    # ── Resolve target month ──
    if event.get("action") == "migrate_previous_month":
        today = datetime.utcnow()
        first_of_this_month = today.replace(day=1)
        last_month = first_of_this_month - timedelta(days=1)
        year = str(last_month.year)
        month = f"{last_month.month:02d}"
        print(f"Computed previous month: {year}-{month}")
    else:
        year = event["year"]
        month = event["month"]

    print(f"Starting ECS task for {year}-{month}")

    try:
        response = ecs_client.run_task(
            cluster=CLUSTER,
            taskDefinition=TASK_DEF,
            launchType="FARGATE",
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": SUBNETS,
                    "securityGroups": [SECURITY_GROUP],
                    "assignPublicIp": "DISABLED"
                }
            },
            overrides={
                "containerOverrides": [
                    {
                        "name": CONTAINER_NAME,
                        "environment": [
                            {"name": "TARGET_YEAR",  "value": year},
                            {"name": "TARGET_MONTH", "value": month},
                        ]
                    }
                ]
            }
        )

        if response.get("failures"):
            failure_msg = json.dumps(response["failures"], indent=2)
            print(f"ECS task failed to start: {failure_msg}")
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"MIGRATION ALERT: ECS task failed to START for {year}-{month}",
                Message=f"Month: {year}-{month}\nFailures:\n{failure_msg}"
            )
            raise Exception(f"ECS task failed to start: {failure_msg}")

        task_arn = response["tasks"][0]["taskArn"]
        print(f"ECS task started: {task_arn}")

        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"Migration STARTED for {year}-{month}",
            Message=f"ECS task started.\nMonth: {year}-{month}\nTask: {task_arn}\n\n"
                    f"Verification will trigger automatically when manifest.json lands in S3."
        )

        return {"status": "started", "year": year, "month": month, "task_arn": task_arn}

    except Exception as e:
        error_msg = str(e)
        print(f"ERROR: {error_msg}")
        if "ECS task failed to start" not in error_msg:
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"MIGRATION ALERT: Orchestrator FAILED for {year}-{month}",
                Message=f"Month: {year}-{month}\nError: {error_msg}"
            )
        raise
