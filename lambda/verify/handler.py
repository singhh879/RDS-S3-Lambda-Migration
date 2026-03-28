"""
Verification Lambda
────────────────────────────────────────────────────────
Triggered by S3 event when manifest.json is uploaded by ECS task.
  S3 key pattern: metadata/YYYY/MM/DD/manifest.json

Checks:
  1. Dump file exists in S3
  2. Dump file size is above minimum threshold
  3. Manifest file is readable and valid JSON
  4. S3 file size matches manifest
  5. Row count from RDS matches manifest

On success: writes verified.json → triggers Drop Partition Lambda.
On failure: does NOT write verified.json (drop never fires) + SNS alert.
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
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

# Configurable via env var — set lower for local testing (e.g. MIN_FILE_SIZE_BYTES=1024)
MIN_FILE_SIZE_BYTES = int(os.environ.get("MIN_FILE_SIZE_BYTES", str(10 * 1024 * 1024)))

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
    # S3 key format: metadata/YYYY/MM/DD/manifest.json
    if "Records" in event:
        s3_event = event["Records"][0]["s3"]
        bucket   = s3_event["bucket"]["name"]
        key      = s3_event["object"]["key"]
        parts    = key.split("/")
        year, month, day = parts[1], parts[2], parts[3]
        print(f"Triggered by S3 event: s3://{bucket}/{key}")
    else:
        year   = event["year"]
        month  = event["month"]
        day    = event["day"]
        bucket = event["bucket"]

    print(f"Verifying backup for {year}-{month}-{day}")

    dump_key     = f"backups/{year}/{month}/{day}/dump_{year}{month}{day}.sql.gz"
    metadata_key = f"metadata/{year}/{month}/{day}/manifest.json"
    checks       = []
    passed       = True

    # ── Check 1: Dump file exists ──
    try:
        resp    = s3_client.head_object(Bucket=bucket, Key=dump_key)
        s3_size = resp["ContentLength"]
        checks.append(f"PASS: Dump exists ({s3_size:,} bytes)")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey"):
            checks.append(f"FAIL: Dump not found at {dump_key}")
            return _finish(False, checks, year, month, day, bucket)
        raise

    # ── Check 2: File size above minimum ──
    if s3_size < MIN_FILE_SIZE_BYTES:
        checks.append(f"FAIL: Size {s3_size:,} below minimum {MIN_FILE_SIZE_BYTES:,}")
        passed = False
    else:
        checks.append("PASS: File size above minimum")

    # ── Check 3: Manifest readable ──
    try:
        manifest = json.loads(
            s3_client.get_object(Bucket=bucket, Key=metadata_key)["Body"].read()
        )
        checks.append("PASS: Manifest found")
    except Exception as e:
        checks.append(f"FAIL: Manifest error: {e}")
        return _finish(False, checks, year, month, day, bucket)

    # ── Check 4: S3 size matches manifest ──
    m_size = manifest.get("file_size_bytes", 0)
    if s3_size != m_size:
        checks.append(f"FAIL: S3 size ({s3_size:,}) != manifest ({m_size:,})")
        passed = False
    else:
        checks.append("PASS: Size matches manifest")

    # ── Check 5: Row count matches RDS ──
    m_rows         = manifest.get("row_count", 0)
    schema_name    = manifest.get("schema_name", "datafeedschema")
    partition_name = manifest.get("partition_name", f"nifty50_table_{year}_{month}_{day}")

    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=_get_db_password(),
            connect_timeout=30
        )
        cur = conn.cursor()
        # Count directly from the specific daily partition — fast, no full scan
        cur.execute(f'SELECT COUNT(*) FROM {schema_name}."{partition_name}"')
        rds_rows = cur.fetchone()[0]
        cur.close()
        conn.close()

        if rds_rows == m_rows:
            checks.append(f"PASS: Rows match — RDS: {rds_rows:,}, Manifest: {m_rows:,}")
        else:
            checks.append(f"FAIL: Rows MISMATCH — RDS: {rds_rows:,}, Manifest: {m_rows:,}")
            passed = False
    except Exception as e:
        checks.append(f"FAIL: RDS error: {e}")
        passed = False

    return _finish(passed, checks, year, month, day, bucket,
                   schema_name=schema_name, partition_name=partition_name)


def _finish(verified, checks, year, month, day, bucket,
            schema_name="datafeedschema", partition_name=None):
    result = {"verified": verified, "details": " | ".join(checks)}
    print(json.dumps(result, indent=2))

    if partition_name is None:
        partition_name = f"nifty50_table_{year}_{month}_{day}"

    if verified:
        s3_client.put_object(
            Bucket=bucket,
            Key=f"metadata/{year}/{month}/{day}/verified.json",
            Body=json.dumps({
                "year": year, "month": month, "day": day,
                "verified": True,
                "checks": checks,
                "verified_at": datetime.utcnow().isoformat() + "Z",
                # Passed forward so drop Lambda is fully table-agnostic
                "schema_name":    schema_name,
                "partition_name": partition_name,
            }, indent=2),
            ContentType="application/json",
            ServerSideEncryption="AES256"
        )
        _notify(f"VERIFIED: {year}-{month}-{day}",
                f"Verification PASSED.\n\n" + "\n".join(f"  {c}" for c in checks)
                + "\n\nDrop partition will execute next.")
    else:
        _notify(f"ALERT: Verification FAILED {year}-{month}-{day}",
                f"Verification FAILED.\n\n" + "\n".join(f"  {c}" for c in checks)
                + "\n\nNO DATA DELETED. Investigate and re-run.")
    return result


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        try:
            sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        except Exception as e:
            print(f"WARNING: SNS failed: {e}")
