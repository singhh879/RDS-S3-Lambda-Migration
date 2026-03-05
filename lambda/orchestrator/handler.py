"""
Orchestrator Lambda — Starts ECS Fargate pg_dump task
─────────────────────────────────────────────────────
Triggered by EventBridge or manual invocation.
Starts the ECS task and exits. Does NOT wait.
The chain continues via S3 events:
  manifest.json upload → Verification Lambda
  verified.json upload → Drop Partition Lambda
"""

import os
import json
import boto3
from datetime import datetime, timedelta

ecs_client = boto3.client("ecs")
sns_client = boto3.client("sns")

CLUSTER        = os.environ["ECS_CLUSTER"]
TASK_DEF       = os.environ["TASK_DEFINITION"]
SUBNETS        = json.loads(os.environ["SUBNETS"])
SECURITY_GROUPS = json.loads(os.environ["SECURITY_GROUPS"])
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
                    "securityGroups": SECURITY_GROUPS,
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
            _notify(f"ALERT: ECS failed to START for {year}-{month}",
                    f"Month: {year}-{month}\nFailures:\n{failure_msg}")
            raise Exception(f"ECS task failed to start: {failure_msg}")

        task_arn = response["tasks"][0]["taskArn"]
        print(f"ECS task started: {task_arn}")

        _notify(f"Migration STARTED: {year}-{month}",
                f"ECS task started.\nMonth: {year}-{month}\nTask: {task_arn}\n\n"
                f"Next: verification triggers automatically when manifest.json lands in S3.")

        return {"status": "started", "year": year, "month": month, "task_arn": task_arn}

    except Exception as e:
        error_msg = str(e)
        print(f"ERROR: {error_msg}")
        if "ECS task failed to start" not in error_msg:
            _notify(f"ALERT: Orchestrator FAILED for {year}-{month}",
                    f"Month: {year}-{month}\nError: {error_msg}")
        raise


def _notify(subject, message):
    try:
        sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
    except Exception as e:
        print(f"WARNING: SNS failed: {e}")
