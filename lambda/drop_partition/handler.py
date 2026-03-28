"""
Drop Partition Lambda
──────────────────────────────────────────────────────
Triggered by S3 event when verified.json is uploaded by Verify Lambda.
  S3 key pattern: metadata/YYYY/MM/DD/verified.json

SAFETY: Reads and validates verified.json before doing anything.
If verified.json is missing, malformed, or verification is False,
this Lambda refuses to drop and sends an alert. Nothing is deleted.
"""

import os
import json
import boto3
import psycopg2
from botocore.exceptions import ClientError
from datetime import datetime

DB_HOST       = os.environ["DB_HOST"]
DB_PORT       = int(os.environ.get("DB_PORT", "5432"))
DB_NAME       = os.environ["DB_NAME"]
DB_USER       = os.environ["DB_USER"]
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
S3_BUCKET     = os.environ.get("S3_BUCKET", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

s3_client  = boto3.client("s3")
sns_client = boto3.client("sns")
sm_client  = boto3.client("secretsmanager")


def _get_db_password():
    """Fetch DB password from Secrets Manager at runtime."""
    secret = json.loads(
        sm_client.get_secret_value(SecretId=DB_SECRET_ARN)["SecretString"]
    )
    return secret["password"]


def lambda_handler(event, context):
    # ── Parse: S3 trigger vs direct invocation ──
    # S3 key format: metadata/YYYY/MM/DD/verified.json
    if "Records" in event:
        s3_event = event["Records"][0]["s3"]
        bucket   = s3_event["bucket"]["name"]
        key      = s3_event["object"]["key"]
        parts    = key.split("/")
        year, month, day = parts[1], parts[2], parts[3]
        print(f"Triggered by S3 event: s3://{bucket}/{key}")
    else:
        year  = event["year"]
        month = event["month"]
        day   = event["day"]
        bucket = S3_BUCKET

    print(f"Drop partition requested for {year}-{month}-{day}")

    # ── Safety: validate verified.json before touching anything ──
    try:
        v_data = json.loads(
            s3_client.get_object(
                Bucket=bucket,
                Key=f"metadata/{year}/{month}/{day}/verified.json"
            )["Body"].read()
        )
        if not v_data.get("verified") or "checks" not in v_data:
            msg = "verified.json invalid or verification not passed. Aborting."
            print(f"ERROR: {msg}")
            _notify(f"ALERT: Drop BLOCKED {year}-{month}-{day}", msg + "\nNO DATA DELETED.")
            raise Exception(msg)
        print(f"Verification confirmed: {len(v_data['checks'])} checks passed")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey"):
            msg = f"verified.json not found for {year}-{month}-{day}. Cannot proceed."
            _notify(f"ALERT: Drop BLOCKED {year}-{month}-{day}", msg)
            raise Exception(msg)
        raise

    # ── Derive partition and schema from verified.json (or fall back to defaults) ──
    schema_name    = v_data.get("schema_name", "datafeedschema")
    partition_name = v_data.get("partition_name", f"nifty50_table_{year}_{month}_{day}")
    # Parent table is derived from partition name: strip the _YYYY_MM_DD suffix
    parent_table   = "_".join(partition_name.split("_")[:-3])

    print(f"Schema:    {schema_name}")
    print(f"Partition: {partition_name}")
    print(f"Parent:    {parent_table}")

    conn = None
    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=_get_db_password(),
            connect_timeout=30
        )
        conn.autocommit = True
        cur = conn.cursor()

        # ── Check partition exists before attempting drop ──
        cur.execute("""
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = %s
                  AND table_name   = %s
            )
        """, (schema_name, partition_name))

        if not cur.fetchone()[0]:
            msg = f"Partition {schema_name}.{partition_name} does not exist. Skipping."
            print(msg)
            _notify(f"MIGRATION SKIPPED: {year}-{month}-{day}", msg)
            return {"success": True, "action": "skipped", "message": msg}

        # ── Detach from parent ──
        print(f"Detaching {schema_name}.{partition_name}...")
        cur.execute(
            f"ALTER TABLE {schema_name}.{parent_table} "
            f"DETACH PARTITION {schema_name}.{partition_name};"
        )

        # ── Drop the now-detached table ──
        print(f"Dropping {schema_name}.{partition_name}...")
        cur.execute(f"DROP TABLE {schema_name}.{partition_name};")

        # NOTE: VACUUM ANALYZE intentionally omitted — it blocks for minutes on
        # a large partitioned table. PostgreSQL autovacuum handles this automatically.

        cur.close()
        conn.close()

        result = {
            "success": True, "action": "dropped",
            "schema": schema_name, "partition": partition_name
        }
        print(json.dumps(result, indent=2))

        _notify(f"MIGRATION COMPLETE: {year}-{month}-{day}",
                f"Partition {schema_name}.{partition_name} dropped.\n"
                f"Backup: s3://{bucket}/backups/{year}/{month}/{day}/\n"
                f"Time: {datetime.utcnow().isoformat()}Z")
        return result

    except Exception as e:
        error_msg = f"Failed to drop {partition_name}: {e}"
        print(f"ERROR: {error_msg}")
        _notify(f"ALERT: Drop FAILED {year}-{month}-{day}",
                f"{error_msg}\n\nBackup safe in S3. Partition NOT dropped.")
        if conn:
            try:
                conn.close()
            except Exception:
                pass
        raise


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        try:
            sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        except Exception as e:
            print(f"WARNING: SNS failed: {e}")
