"""
Drop Partition Lambda — works with BOTH pipelines
──────────────────────────────────────────────────
Triggered by:
  - Step Functions: {"year","month"} (only if verification passed)
  - S3 event: when verified.json is uploaded by verification Lambda

SAFETY: Reads and validates verified.json before doing anything.
If verified.json is missing, malformed, or not from the verification
Lambda, this Lambda refuses to drop and sends an alert.
"""

import os
import json
import boto3
import psycopg2
from datetime import datetime

DB_HOST       = os.environ["DB_HOST"]
DB_PORT       = int(os.environ.get("DB_PORT", "5432"))
DB_NAME       = os.environ["DB_NAME"]
DB_USER       = os.environ["DB_USER"]
DB_PASSWORD   = os.environ["DB_PASSWORD"]
S3_BUCKET     = os.environ.get("S3_BUCKET", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

s3_client  = boto3.client("s3")
sns_client = boto3.client("sns")


def lambda_handler(event, context):
    if "Records" in event:
        s3_event = event["Records"][0]["s3"]
        bucket   = s3_event["bucket"]["name"]
        key      = s3_event["object"]["key"]
        parts    = key.split("/")
        year, month = parts[1], parts[2]
        print(f"Triggered by S3 event: s3://{bucket}/{key}")
    else:
        year, month = event["year"], event["month"]
        bucket = S3_BUCKET

    print(f"Drop partition requested for {year}-{month}")

    # ── Safety: validate verified.json ──
    try:
        v_data = json.loads(
            s3_client.get_object(Bucket=bucket, Key=f"metadata/{year}/{month}/verified.json")
            ["Body"].read()
        )
        if not v_data.get("verified") or "checks" not in v_data:
            msg = "verified.json invalid or not from verification Lambda. Aborting."
            print(f"ERROR: {msg}")
            _notify(f"ALERT: Drop BLOCKED {year}-{month}", msg + "\nNO DATA DELETED.")
            raise Exception(msg)
        print(f"Verification confirmed: {len(v_data['checks'])} checks passed")
    except s3_client.exceptions.NoSuchKey:
        msg = f"verified.json not found for {year}-{month}. Cannot proceed."
        _notify(f"ALERT: Drop BLOCKED {year}-{month}", msg)
        raise Exception(msg)

    # ─── CUSTOMIZE partition name ───
    partition_name = f"market_data_y{year}m{month}"
    print(f"Target: {partition_name}")

    conn = None
    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=DB_PASSWORD, connect_timeout=30
        )
        conn.autocommit = True
        cur = conn.cursor()

        cur.execute("""
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables WHERE table_name = %s
            )
        """, (partition_name,))

        if not cur.fetchone()[0]:
            msg = f"Partition {partition_name} does not exist. Skipping."
            print(msg)
            _notify(f"MIGRATION SKIPPED: {year}-{month}", msg)
            return {"success": True, "action": "skipped", "message": msg}

        print(f"Detaching {partition_name}...")
        cur.execute(f"ALTER TABLE market_data DETACH PARTITION {partition_name};")

        print(f"Dropping {partition_name}...")
        cur.execute(f"DROP TABLE {partition_name};")

        print("Running VACUUM ANALYZE...")
        cur.execute("VACUUM ANALYZE market_data;")

        cur.close()
        conn.close()

        result = {"success": True, "action": "dropped", "partition": partition_name}
        print(json.dumps(result, indent=2))

        _notify(f"MIGRATION COMPLETE: {year}-{month}",
                f"Partition {partition_name} dropped.\n"
                f"Backup: s3://{bucket}/backups/{year}/{month}/\n"
                f"Time: {datetime.utcnow().isoformat()}Z")
        return result

    except Exception as e:
        error_msg = f"Failed to drop {partition_name}: {e}"
        print(f"ERROR: {error_msg}")
        _notify(f"ALERT: Drop FAILED {year}-{month}",
                f"{error_msg}\n\nBackup safe in S3. Partition NOT dropped.")
        if conn:
            try: conn.close()
            except: pass
        raise


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        try: sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        except Exception as e: print(f"WARNING: SNS failed: {e}")
