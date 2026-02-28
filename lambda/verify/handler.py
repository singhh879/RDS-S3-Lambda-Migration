"""
Verification Lambda — works with BOTH pipelines
─────────────────────────────────────────────────
Triggered by:
  - Step Functions: {"year","month","bucket"}
  - S3 event: when manifest.json is uploaded by ECS task

Checks: file exists, file size, manifest exists, sizes match, row count matches RDS.
On success: writes verified.json to S3 (triggers drop Lambda in chain mode) + SNS.
On failure: does NOT write verified.json (drop Lambda never fires) + SNS alert.
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
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

MIN_FILE_SIZE_BYTES = 10 * 1024 * 1024

s3_client  = boto3.client("s3")
sns_client = boto3.client("sns")


def lambda_handler(event, context):
    # ── Parse: S3 trigger vs direct invocation ──
    if "Records" in event:
        s3_event = event["Records"][0]["s3"]
        bucket   = s3_event["bucket"]["name"]
        key      = s3_event["object"]["key"]
        parts    = key.split("/")
        year, month = parts[1], parts[2]
        print(f"Triggered by S3 event: s3://{bucket}/{key}")
    else:
        year, month, bucket = event["year"], event["month"], event["bucket"]

    print(f"Verifying backup for {year}-{month}")

    dump_key     = f"backups/{year}/{month}/dump_{year}{month}.sql.gz"
    metadata_key = f"metadata/{year}/{month}/manifest.json"
    checks       = []
    passed       = True

    # Check 1: Dump file exists
    try:
        resp = s3_client.head_object(Bucket=bucket, Key=dump_key)
        s3_size = resp["ContentLength"]
        checks.append(f"PASS: Dump exists ({s3_size:,} bytes)")
    except s3_client.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "404":
            checks.append(f"FAIL: Dump not found at {dump_key}")
            return _finish(False, checks, year, month, bucket)
        raise

    # Check 2: File size threshold
    if s3_size < MIN_FILE_SIZE_BYTES:
        checks.append(f"FAIL: Size {s3_size:,} below minimum {MIN_FILE_SIZE_BYTES:,}")
        passed = False
    else:
        checks.append("PASS: File size above minimum")

    # Check 3: Manifest exists
    try:
        manifest = json.loads(
            s3_client.get_object(Bucket=bucket, Key=metadata_key)["Body"].read()
        )
        checks.append("PASS: Manifest found")
    except Exception as e:
        checks.append(f"FAIL: Manifest error: {e}")
        return _finish(False, checks, year, month, bucket)

    # Check 4: Size matches manifest
    m_size = manifest.get("file_size_bytes", 0)
    if s3_size != m_size:
        checks.append(f"FAIL: S3 size ({s3_size:,}) != manifest ({m_size:,})")
        passed = False
    else:
        checks.append("PASS: Size matches manifest")

    # Check 5: Row count matches RDS
    m_rows = manifest.get("row_count", 0)
    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=DB_PASSWORD, connect_timeout=30
        )
        cur = conn.cursor()
        # ─── CUSTOMIZE table name and date column ───
        cur.execute("""
            SELECT COUNT(*) FROM market_data
            WHERE trade_date >= %s AND trade_date < %s::date + INTERVAL '1 month'
        """, (f"{year}-{month}-01", f"{year}-{month}-01"))
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

    return _finish(passed, checks, year, month, bucket)


def _finish(verified, checks, year, month, bucket):
    result = {"verified": verified, "details": " | ".join(checks)}
    print(json.dumps(result, indent=2))

    if verified:
        s3_client.put_object(
            Bucket=bucket,
            Key=f"metadata/{year}/{month}/verified.json",
            Body=json.dumps({
                "year": year, "month": month, "verified": True,
                "checks": checks, "verified_at": datetime.utcnow().isoformat() + "Z"
            }, indent=2),
            ContentType="application/json",
            ServerSideEncryption="AES256"
        )
        _notify(f"VERIFIED: {year}-{month}",
                f"Verification PASSED.\n\n" + "\n".join(f"  {c}" for c in checks)
                + "\n\nDrop partition will execute next.")
    else:
        _notify(f"ALERT: Verification FAILED {year}-{month}",
                f"Verification FAILED.\n\n" + "\n".join(f"  {c}" for c in checks)
                + "\n\nNO DATA DELETED. Investigate and re-run.")
    return result


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        try:
            sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        except Exception as e:
            print(f"WARNING: SNS failed: {e}")
