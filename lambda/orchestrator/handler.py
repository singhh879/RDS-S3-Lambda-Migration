"""
Orchestrator Lambda — Starts ECS Fargate pg_dump tasks
───────────────────────────────────────────────────────
Triggered by EventBridge (1st of every month) or manual invocation.
Launches ECS tasks and exits immediately — does NOT wait for completion.
The chain continues automatically via S3 events:
  manifest.json upload  →  Verify Lambda
  verified.json upload  →  Drop Partition Lambda

Supported actions
─────────────────
1. migrate_previous_month  (EventBridge trigger)
   Computes the previous calendar month and launches one ECS task
   per day of that month, staggered 10 seconds apart.
   e.g. fires on 2025-10-01 → migrates all daily partitions in Sep 2025

2. migrate_month  (manual batch trigger)
   Same as above but for an explicit year/month.
   Payload: {"action": "migrate_month", "year": "2025", "month": "09"}

3. Single day  (manual per-day trigger)
   Launches one ECS task for a specific date.
   Payload: {"year": "2025", "month": "09", "day": "01"}
"""

import os
import json
import time
import calendar
import boto3
from datetime import datetime, timedelta

ecs_client = boto3.client("ecs")
sns_client = boto3.client("sns")

CLUSTER         = os.environ["ECS_CLUSTER"]
TASK_DEF        = os.environ["TASK_DEFINITION"]
SUBNETS         = json.loads(os.environ["SUBNETS"])
SECURITY_GROUPS = json.loads(os.environ["SECURITY_GROUPS"])
SNS_TOPIC_ARN   = os.environ["SNS_TOPIC_ARN"]
CONTAINER_NAME  = os.environ.get("CONTAINER_NAME", "export")

# Seconds between consecutive ECS task launches.
# 31 days x 10s = 310s total stagger — comfortably within the 420s Lambda timeout.
# Spreads RDS connection ramp-up; tasks still run mostly concurrently.
LAUNCH_STAGGER_SECONDS = 10


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")
    action = event.get("action", "")

    # Action 1: EventBridge monthly trigger
    if action == "migrate_previous_month":
        today         = datetime.utcnow()
        last_day_prev = today.replace(day=1) - timedelta(days=1)
        year          = str(last_day_prev.year)
        month         = f"{last_day_prev.month:02d}"
        print(f"Computed previous month: {year}-{month}")
        return _migrate_month(year, month)

    # Action 2: Manual batch trigger for a specific month
    elif action == "migrate_month":
        year  = event["year"]
        month = event["month"]
        return _migrate_month(year, month)

    # Action 3: Manual single-day trigger
    else:
        year  = event["year"]
        month = event["month"]
        day   = event["day"]
        return _launch_single_task(year, month, day)


def _migrate_month(year, month):
    """
    Launch one ECS task per calendar day in year/month, staggered 10s apart.
    Continues even if individual launches fail — reports a full summary at end.
    Lambda timeout is 420s in Terraform, handling 31 days x 10s (310s) + overhead.
    """
    _, num_days = calendar.monthrange(int(year), int(month))
    print(f"Launching {num_days} ECS tasks for {year}-{month} "
          f"(stagger: {LAUNCH_STAGGER_SECONDS}s between each)")

    launched = []
    failed   = []

    for d in range(1, num_days + 1):
        day = f"{d:02d}"
        try:
            result = _launch_single_task(year, month, day)
            launched.append(result)
            print(f"  [{d:02d}/{num_days}] Launched {year}-{month}-{day} "
                  f"-> {result['task_arn'].split('/')[-1]}")
        except Exception as e:
            failed.append({"day": day, "error": str(e)})
            print(f"  [{d:02d}/{num_days}] FAILED  {year}-{month}-{day} -- {e}")

        # Stagger: sleep between launches (skip after the last task)
        if d < num_days:
            time.sleep(LAUNCH_STAGGER_SECONDS)

    summary = {
        "action":     "migrate_month",
        "year":       year,
        "month":      month,
        "total_days": num_days,
        "launched":   len(launched),
        "failed":     len(failed),
        "failures":   failed,
    }
    print(json.dumps(summary, indent=2))

    if failed:
        _notify(
            f"Migration PARTIAL: {year}-{month}",
            f"{len(launched)}/{num_days} tasks launched.\n"
            f"Failed days: {[f['day'] for f in failed]}\n"
            f"Re-trigger failed days individually. Check CloudWatch for details."
        )
    else:
        _notify(
            f"Migration STARTED: {year}-{month} ({num_days} tasks)",
            f"All {num_days} ECS tasks launched with {LAUNCH_STAGGER_SECONDS}s stagger.\n"
            f"Tasks will complete in ~10-15 minutes.\n"
            f"You will receive a notification as each partition completes."
        )

    return summary


def _launch_single_task(year, month, day):
    """Launch one ECS Fargate task for a specific date. Raises on any failure."""
    try:
        response = ecs_client.run_task(
            cluster=CLUSTER,
            taskDefinition=TASK_DEF,
            launchType="FARGATE",
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets":        SUBNETS,
                    "securityGroups": SECURITY_GROUPS,
                    "assignPublicIp": "DISABLED",
                }
            },
            overrides={
                "containerOverrides": [{
                    "name": CONTAINER_NAME,
                    "environment": [
                        {"name": "TARGET_YEAR",  "value": year},
                        {"name": "TARGET_MONTH", "value": month},
                        {"name": "TARGET_DAY",   "value": day},
                    ]
                }]
            }
        )

        if response.get("failures"):
            raise Exception(f"ECS launch failure: {json.dumps(response['failures'])}")

        task_arn = response["tasks"][0]["taskArn"]
        return {
            "status":   "started",
            "year":     year,
            "month":    month,
            "day":      day,
            "task_arn": task_arn,
        }

    except Exception as e:
        print(f"ERROR launching {year}-{month}-{day}: {e}")
        _notify(
            f"ALERT: ECS launch FAILED {year}-{month}-{day}",
            f"Date: {year}-{month}-{day}\nError: {str(e)}"
        )
        raise


def _notify(subject, message):
    try:
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message
        )
    except Exception as e:
        print(f"WARNING: SNS failed: {e}")
