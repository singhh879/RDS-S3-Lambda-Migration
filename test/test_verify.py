"""
test_verify.py — Unit tests for the Verify Lambda handler
──────────────────────────────────────────────────────────
Tests all 5 verification checks using:
  - moto  → mocked S3 + Secrets Manager (no real AWS calls)
  - psycopg2 → real local Postgres (localhost:5433)

Prerequisites:
  docker compose up -d   (marsquant-test-postgres must be running)
  pip install -r test/requirements.txt

Run:
  python test/test_verify.py           # unittest runner
  python -m pytest test/test_verify.py # pytest (optional)
"""

import os
import sys
import json
import gzip
import unittest
import psycopg2
from botocore.exceptions import ClientError

# ── Fake AWS credentials so boto3 doesn't complain ──────────────────────────
os.environ.setdefault("AWS_DEFAULT_REGION",    "ap-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID",     "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN",    "testing")
os.environ.setdefault("AWS_SESSION_TOKEN",     "testing")

# ── Test DB connection details ───────────────────────────────────────────────
TEST_DB_HOST = os.environ.get("TEST_DB_HOST", "localhost")
TEST_DB_PORT = int(os.environ.get("TEST_DB_PORT", "5433"))
TEST_DB_NAME = "datafeeddatabase"
TEST_DB_USER = "marsquantMasterUser"
TEST_DB_PASS = "testpassword"

# Secret *name* — moto supports lookup by name or ARN
SECRET_ID = "test/db-password"

# ── Set handler env vars BEFORE importing the module ────────────────────────
os.environ.update({
    "DB_HOST":              TEST_DB_HOST,
    "DB_PORT":              str(TEST_DB_PORT),
    "DB_NAME":              TEST_DB_NAME,
    "DB_USER":              TEST_DB_USER,
    "DB_SECRET_ARN":        SECRET_ID,
    "SNS_TOPIC_ARN":        "",
    "MIN_FILE_SIZE_BYTES":  "1024",   # ← lowered for test data (~2 KB dump)
})

# ── Import handler (module-level clients created here) ──────────────────────
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "verify"))
import handler as verify_handler  # noqa: E402

import boto3          # noqa: E402
from moto import mock_aws  # noqa: E402

# ── Constants ────────────────────────────────────────────────────────────────
TEST_BUCKET  = "marsquant-test-bucket"
REGION       = "ap-south-1"
YEAR, MONTH, DAY = "2025", "09", "01"
DUMP_KEY     = f"backups/{YEAR}/{MONTH}/{DAY}/dump_{YEAR}{MONTH}{DAY}.sql.gz"
MANIFEST_KEY = f"metadata/{YEAR}/{MONTH}/{DAY}/manifest.json"
VERIFIED_KEY = f"metadata/{YEAR}/{MONTH}/{DAY}/verified.json"
PARTITION    = f"nifty50_table_{YEAR}_{MONTH}_{DAY}"
SCHEMA       = "datafeedschema"

S3_TRIGGER_EVENT = {
    "Records": [{"s3": {
        "bucket": {"name": TEST_BUCKET},
        "object": {"key": MANIFEST_KEY},
    }}]
}


# ── Helpers ──────────────────────────────────────────────────────────────────

def _make_fake_dump():
    """~2 KB compressed (random bytes prevent over-compression below 1 024 B)."""
    header  = b"-- fake pg_dump: nifty50_table_2025_09_01\n"
    payload = os.urandom(2048)          # random = incompressible
    return gzip.compress(header + payload)


def _make_manifest(bucket, row_count, file_size,
                   schema=SCHEMA, partition=PARTITION):
    return json.dumps({
        "year": YEAR, "month": MONTH, "day": DAY,
        "table_name":      "nifty50_table",
        "schema_name":     schema,
        "partition_name":  partition,
        "s3_bucket":       bucket,
        "s3_key":          DUMP_KEY,
        "file_size_bytes": file_size,
        "md5_checksum":    "deadbeef",
        "row_count":       row_count,
        "dump_duration_seconds": 12,
        "timestamp": "2025-09-01T23:30:00Z",
    }).encode()


def _get_real_row_count():
    """Fetch actual row count from local test DB for the test partition."""
    conn = psycopg2.connect(
        host=TEST_DB_HOST, port=TEST_DB_PORT,
        dbname=TEST_DB_NAME, user=TEST_DB_USER, password=TEST_DB_PASS,
    )
    cur = conn.cursor()
    cur.execute(f'SELECT COUNT(*) FROM {SCHEMA}."{PARTITION}"')
    count = cur.fetchone()[0]
    cur.close()
    conn.close()
    return count


# ── Test class ───────────────────────────────────────────────────────────────

class TestVerifyHandler(unittest.TestCase):

    def _setup_aws(self):
        """
        Create mocked AWS resources and wire them into the handler module.
        Must be called INSIDE a @mock_aws context so clients use moto endpoints.
        """
        s3  = boto3.client("s3",              region_name=REGION)
        sm  = boto3.client("secretsmanager",  region_name=REGION)
        sns = boto3.client("sns",              region_name=REGION)

        # ← Critical: replace module-level clients with mocked ones
        verify_handler.s3_client  = s3
        verify_handler.sm_client  = sm
        verify_handler.sns_client = sns

        # Create the bucket and secret
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
    def test_1_verify_pass(self):
        """All 5 checks pass → verified=True, verified.json written to S3."""
        s3, _, _ = self._setup_aws()

        real_rows  = _get_real_row_count()
        fake_dump  = _make_fake_dump()
        manifest   = _make_manifest(TEST_BUCKET, real_rows, len(fake_dump))

        s3.put_object(Bucket=TEST_BUCKET, Key=DUMP_KEY,     Body=fake_dump)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        result = verify_handler.lambda_handler(S3_TRIGGER_EVENT, None)

        self.assertTrue(result["verified"],
                        f"Expected verified=True.\nDetails: {result['details']}")
        print(f"  checks: {result['details']}")

        # verified.json must exist and carry schema/partition info
        v_body = json.loads(
            s3.get_object(Bucket=TEST_BUCKET, Key=VERIFIED_KEY)["Body"].read()
        )
        self.assertTrue(v_body["verified"])
        self.assertEqual(v_body["schema_name"],    SCHEMA)
        self.assertEqual(v_body["partition_name"], PARTITION)
        print(f"  verified.json written correctly ✓")

    # ── Test 2: row count mismatch ────────────────────────────────────────────
    @mock_aws
    def test_2_fail_row_mismatch(self):
        """Manifest row count != RDS → verified=False, verified.json NOT written."""
        s3, _, _ = self._setup_aws()

        fake_dump = _make_fake_dump()
        manifest  = _make_manifest(TEST_BUCKET, 9_999_999, len(fake_dump))  # wrong count

        s3.put_object(Bucket=TEST_BUCKET, Key=DUMP_KEY,     Body=fake_dump)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        result = verify_handler.lambda_handler(S3_TRIGGER_EVENT, None)

        self.assertFalse(result["verified"])
        self.assertIn("MISMATCH", result["details"])
        print(f"  row mismatch detected ✓  details: {result['details']}")

        # verified.json must NOT exist
        with self.assertRaises(ClientError) as ctx:
            s3.get_object(Bucket=TEST_BUCKET, Key=VERIFIED_KEY)
        self.assertIn(
            ctx.exception.response["Error"]["Code"], ("NoSuchKey", "404"),
        )
        print(f"  verified.json correctly absent ✓")

    # ── Test 3: dump file missing ─────────────────────────────────────────────
    @mock_aws
    def test_3_fail_dump_not_found(self):
        """Dump file absent → early return, verified=False."""
        s3, _, _ = self._setup_aws()

        # Upload manifest but NO dump
        manifest = _make_manifest(TEST_BUCKET, 5000, 50000)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        result = verify_handler.lambda_handler(S3_TRIGGER_EVENT, None)

        self.assertFalse(result["verified"])
        self.assertIn("FAIL", result["details"])
        print(f"  dump-not-found detected ✓  details: {result['details']}")

    # ── Test 4: file size below minimum ──────────────────────────────────────
    @mock_aws
    def test_4_fail_size_below_minimum(self):
        """Dump < MIN_FILE_SIZE_BYTES (1 024 B) → verified=False."""
        s3, _, _ = self._setup_aws()

        tiny_dump = b"x" * 10   # 10 bytes, well below 1 024
        manifest  = _make_manifest(TEST_BUCKET, 5000, len(tiny_dump))

        s3.put_object(Bucket=TEST_BUCKET, Key=DUMP_KEY,     Body=tiny_dump)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        result = verify_handler.lambda_handler(S3_TRIGGER_EVENT, None)

        self.assertFalse(result["verified"])
        self.assertIn("below minimum", result["details"])
        print(f"  size-below-minimum detected ✓  details: {result['details']}")

    # ── Test 5: size mismatch between S3 and manifest ────────────────────────
    @mock_aws
    def test_5_fail_size_mismatch(self):
        """S3 object size != manifest file_size_bytes → verified=False."""
        s3, _, _ = self._setup_aws()

        real_rows = _get_real_row_count()
        fake_dump = _make_fake_dump()
        manifest  = _make_manifest(
            TEST_BUCKET, real_rows,
            len(fake_dump) + 9999,   # ← intentionally wrong size in manifest
        )

        s3.put_object(Bucket=TEST_BUCKET, Key=DUMP_KEY,     Body=fake_dump)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        result = verify_handler.lambda_handler(S3_TRIGGER_EVENT, None)

        self.assertFalse(result["verified"])
        self.assertIn("S3 size", result["details"])
        print(f"  size-mismatch detected ✓  details: {result['details']}")

    # ── Test 6: direct invocation (no S3 Records) ────────────────────────────
    @mock_aws
    def test_6_direct_invocation(self):
        """Handler can be invoked directly (not via S3 event) with explicit date."""
        s3, _, _ = self._setup_aws()

        real_rows = _get_real_row_count()
        fake_dump = _make_fake_dump()
        manifest  = _make_manifest(TEST_BUCKET, real_rows, len(fake_dump))

        s3.put_object(Bucket=TEST_BUCKET, Key=DUMP_KEY,     Body=fake_dump)
        s3.put_object(Bucket=TEST_BUCKET, Key=MANIFEST_KEY, Body=manifest)

        direct_event = {
            "year": YEAR, "month": MONTH, "day": DAY,
            "bucket": TEST_BUCKET,
        }
        result = verify_handler.lambda_handler(direct_event, None)
        self.assertTrue(result["verified"])
        print(f"  direct invocation succeeded ✓")


if __name__ == "__main__":
    unittest.main(verbosity=2)
