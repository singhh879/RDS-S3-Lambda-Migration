"""
test_drop.py — Unit tests for the Drop Partition Lambda handler
────────────────────────────────────────────────────────────────
Tests all guard-rails and the happy path using:
  - moto  → mocked S3 + Secrets Manager (no real AWS calls)
  - psycopg2 → real local Postgres (localhost:5433)

IMPORTANT — sequencing:
  test_drop_happy_path physically DROPs nifty50_table_2025_09_02.
  Run test_full_chain.sh (or docker compose down -v && up) to reset.

Prerequisites:
  docker compose up -d   (marsquant-test-postgres must be running)
  pip install -r test/requirements.txt

Run:
  python test/test_drop.py
"""

import os
import sys
import json
import unittest
from datetime import datetime

import psycopg2
from botocore.exceptions import ClientError

# ── Fake AWS credentials ─────────────────────────────────────────────────────
os.environ.setdefault("AWS_DEFAULT_REGION",    "ap-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID",     "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN",    "testing")
os.environ.setdefault("AWS_SESSION_TOKEN",     "testing")

# ── Test DB details ──────────────────────────────────────────────────────────
TEST_DB_HOST = os.environ.get("TEST_DB_HOST", "localhost")
TEST_DB_PORT = int(os.environ.get("TEST_DB_PORT", "5433"))
TEST_DB_NAME = "datafeeddatabase"
TEST_DB_USER = "marsquantMasterUser"
TEST_DB_PASS = "testpassword"

SECRET_ID = "test/db-password"

# ── Handler env vars (set BEFORE import) ─────────────────────────────────────
os.environ.update({
    "DB_HOST":       TEST_DB_HOST,
    "DB_PORT":       str(TEST_DB_PORT),
    "DB_NAME":       TEST_DB_NAME,
    "DB_USER":       TEST_DB_USER,
    "DB_SECRET_ARN": SECRET_ID,
    "S3_BUCKET":     "marsquant-test-bucket",
    "SNS_TOPIC_ARN": "",
})

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "drop_partition"))
import handler as drop_handler  # noqa: E402

import boto3          # noqa: E402
from moto import mock_aws  # noqa: E402

# ── Constants ────────────────────────────────────────────────────────────────
TEST_BUCKET = "marsquant-test-bucket"
REGION      = "ap-south-1"
SCHEMA      = "datafeedschema"

# Use partition _02 for the happy-path drop so _01 stays intact for verify tests
YEAR, MONTH, DAY = "2025", "09", "02"
PARTITION        = f"nifty50_table_{YEAR}_{MONTH}_{DAY}"
VERIFIED_KEY     = f"metadata/{YEAR}/{MONTH}/{DAY}/verified.json"


# ── Helpers ──────────────────────────────────────────────────────────────────

def _make_verified_json(verified=True, schema=SCHEMA, partition=PARTITION,
                        year=YEAR, month=MONTH, day=DAY):
    return json.dumps({
        "year": year, "month": month, "day": day,
        "verified":       verified,
        "checks":         ["PASS: Dump exists", "PASS: File size above minimum",
                           "PASS: Manifest found", "PASS: Size matches manifest",
                           "PASS: Rows match"],
        "verified_at":    datetime.utcnow().isoformat() + "Z",
        "schema_name":    schema,
        "partition_name": partition,
    }).encode()


def _db_conn():
    return psycopg2.connect(
        host=TEST_DB_HOST, port=TEST_DB_PORT,
        dbname=TEST_DB_NAME, user=TEST_DB_USER, password=TEST_DB_PASS,
    )


def _partition_exists(partition_name, schema=SCHEMA):
    conn = _db_conn()
    cur  = conn.cursor()
    cur.execute("""
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = %s AND table_name = %s
        )
    """, (schema, partition_name))
    exists = cur.fetchone()[0]
    cur.close()
    conn.close()
    return exists


def _s3_event(bucket, key):
    return {"Records": [{"s3": {"bucket": {"name": bucket}, "object": {"key": key}}}]}


# ── Test class ───────────────────────────────────────────────────────────────

class TestDropPartitionHandler(unittest.TestCase):

    def _setup_aws(self):
        """
        Create mocked S3 + SM clients and wire them into the handler module.
        Must be called INSIDE a @mock_aws context.
        """
        s3  = boto3.client("s3",             region_name=REGION)
        sm  = boto3.client("secretsmanager", region_name=REGION)
        sns = boto3.client("sns",            region_name=REGION)

        drop_handler.s3_client  = s3
        drop_handler.sm_client  = sm
        drop_handler.sns_client = sns

        s3.create_bucket(
            Bucket=TEST_BUCKET,
            CreateBucketConfiguration={"LocationConstraint": REGION},
        )
        sm.create_secret(
            Name=SECRET_ID,
            SecretString=json.dumps({"password": TEST_DB_PASS}),
        )
        return s3, sm, sns

    # ── Test 1: happy path ───────────────────────────────────────────────────
    @mock_aws
    def test_1_drop_happy_path(self):
        """
        Partition exists + verified.json valid → partition detached and dropped.
        NOTE: This test physically drops nifty50_table_2025_09_02 from the DB.
        """
        s3, _, _ = self._setup_aws()

        # Confirm partition exists before drop
        self.assertTrue(
            _partition_exists(PARTITION),
            f"Setup error: partition {PARTITION} not found — is test DB up?",
        )
        print(f"  {PARTITION} confirmed in DB ✓")

        s3.put_object(Bucket=TEST_BUCKET, Key=VERIFIED_KEY,
                      Body=_make_verified_json())

        result = drop_handler.lambda_handler(_s3_event(TEST_BUCKET, VERIFIED_KEY), None)

        self.assertTrue(result["success"])
        self.assertEqual(result["action"], "dropped")
        self.assertEqual(result["schema"],    SCHEMA)
        self.assertEqual(result["partition"], PARTITION)
        print(f"  drop result: {result} ✓")

        # Confirm partition is gone
        self.assertFalse(
            _partition_exists(PARTITION),
            f"Partition {PARTITION} should have been dropped",
        )
        print(f"  {PARTITION} confirmed dropped from DB ✓")

    # ── Test 2: verified.json absent → blocked ────────────────────────────────
    @mock_aws
    def test_2_blocked_no_verified_json(self):
        """verified.json missing → Exception raised, nothing dropped."""
        s3, _, _ = self._setup_aws()

        # Don't upload verified.json at all
        with self.assertRaises(Exception) as ctx:
            drop_handler.lambda_handler(_s3_event(TEST_BUCKET, VERIFIED_KEY), None)

        self.assertIn("not found", str(ctx.exception).lower())
        print(f"  blocked (no verified.json): {ctx.exception} ✓")

    # ── Test 3: verified=False in JSON → blocked ──────────────────────────────
    @mock_aws
    def test_3_blocked_failed_verification(self):
        """verified.json present but verified=False → Exception, nothing dropped."""
        s3, _, _ = self._setup_aws()

        # Use _03 partition (still exists, not dropped in test_1)
        p3_key = "metadata/2025/09/03/verified.json"
        s3.put_object(
            Bucket=TEST_BUCKET, Key=p3_key,
            Body=_make_verified_json(
                verified=False,
                partition="nifty50_table_2025_09_03",
                year="2025", month="09", day="03",
            ),
        )

        with self.assertRaises(Exception) as ctx:
            drop_handler.lambda_handler(_s3_event(TEST_BUCKET, p3_key), None)

        print(f"  blocked (verified=False): {ctx.exception} ✓")
        # Partition _03 must still be there
        self.assertTrue(_partition_exists("nifty50_table_2025_09_03"))
        print(f"  nifty50_table_2025_09_03 untouched ✓")

    # ── Test 4: partition already gone → skipped gracefully ──────────────────
    @mock_aws
    def test_4_skip_already_dropped(self):
        """Partition doesn't exist (re-run scenario) → success with action=skipped."""
        s3, _, _ = self._setup_aws()

        # Use a day we never created a partition for
        ghost_key       = "metadata/2025/09/04/verified.json"
        ghost_partition = "nifty50_table_2025_09_04"

        s3.put_object(
            Bucket=TEST_BUCKET, Key=ghost_key,
            Body=_make_verified_json(
                partition=ghost_partition, year="2025", month="09", day="04",
            ),
        )

        result = drop_handler.lambda_handler(
            _s3_event(TEST_BUCKET, ghost_key), None
        )

        self.assertTrue(result["success"])
        self.assertEqual(result["action"], "skipped")
        print(f"  idempotent skip: {result['message']} ✓")

    # ── Test 5: direct invocation (no S3 Records key) ────────────────────────
    @mock_aws
    def test_5_direct_invocation_blocked_no_verified(self):
        """Direct invocation without verified.json → Exception."""
        s3, _, _ = self._setup_aws()

        # S3_BUCKET env var is set; no verified.json uploaded
        direct_event = {"year": "2025", "month": "09", "day": "05"}

        with self.assertRaises(Exception):
            drop_handler.lambda_handler(direct_event, None)

        print(f"  direct invocation correctly blocked without verified.json ✓")


if __name__ == "__main__":
    unittest.main(verbosity=2)
