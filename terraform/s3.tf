# ──────────────────────────────────────────────
# S3 Bucket — Migration Data Archive
# ──────────────────────────────────────────────
# This bucket stores the pg_dump files exported from RDS.
#
# STRUCTURE:
#   s3://marsquant-market-data-archive/
#   ├── backups/
#   │   ├── 2025/
#   │   │   ├── 02/
#   │   │   │   └── nifty_mcx_202502.sql.gz    (Feb 2025 dump)
#   │   │   ├── 03/
#   │   │   │   └── nifty_mcx_202503.sql.gz    (Mar 2025 dump)
#   │   │   └── ...
#   │   └── 2026/
#   │       ├── 01/
#   │       │   └── nifty_mcx_202601.sql.gz
#   │       └── ...
#   └── metadata/
#       └── 2025/
#           └── 02/
#               └── manifest.json              (row count, file size, checksum)
#
# SAFETY FEATURES:
#   - Versioning: ON (accidental overwrite? previous version recoverable)
#   - Encryption: AES-256 (data encrypted at rest)
#   - Public access: BLOCKED (all of it)
#   - Lifecycle rules: move to cheaper storage after 90/180 days
#
# COST BREAKDOWN (1700 GB of pg_dump .sql.gz files):
#   S3 Standard:       ~₹3,150/mo  (first 90 days)
#   S3 Standard-IA:    ~₹1,600/mo  (after 90 days, ~50% cheaper)
#   S3 Glacier Instant: ~₹750/mo   (after 180 days, rarely accessed)
# ──────────────────────────────────────────────


# ─── The Bucket ───

resource "aws_s3_bucket" "data_archive" {
  bucket = var.s3_bucket_name

  # Prevent accidental deletion of the bucket via terraform destroy
  # Remove this ONLY if you intentionally want to delete the bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = var.s3_bucket_name
  }
}


# ─── Versioning ───
# If a file is overwritten or deleted, the previous version is kept.
# This is your safety net during migration. You can recover any
# accidentally overwritten dump file.

resource "aws_s3_bucket_versioning" "data_archive" {
  bucket = aws_s3_bucket.data_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}


# ─── Encryption ───
# All objects encrypted at rest using AES-256 (SSE-S3).
# This is free and automatic — no KMS key management needed.

resource "aws_s3_bucket_server_side_encryption_configuration" "data_archive" {
  bucket = aws_s3_bucket.data_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}


# ─── Block ALL Public Access ───
# Financial data should never be publicly accessible.
# This is a belt-and-suspenders measure on top of IAM policies.

resource "aws_s3_bucket_public_access_block" "data_archive" {
  bucket = aws_s3_bucket.data_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ─── Lifecycle Rules ───
# These automatically move data to cheaper storage tiers over time.
# You don't need to do anything — AWS handles the transitions.
#
# Why three tiers:
#   Standard (first 90 days): fastest access, you might need to re-verify
#   Standard-IA (90-180 days): slightly slower first-byte, ~50% cheaper
#   Glacier Instant Retrieval (180+ days): millisecond access, ~75% cheaper
#
# We also clean up:
#   - Old versions after 30 days (versioning creates copies on overwrite)
#   - Incomplete multipart uploads after 7 days (failed uploads leave debris)

resource "aws_s3_bucket_lifecycle_configuration" "data_archive" {
  bucket = aws_s3_bucket.data_archive.id

  # Depends on versioning being enabled first
  depends_on = [aws_s3_bucket_versioning.data_archive]

  # Rule 1: Transition backup files to cheaper tiers over time
  rule {
    id     = "archive-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    # After 90 days: move to Standard-IA (Infrequent Access)
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    # After 180 days: move to Glacier Instant Retrieval
    # Still millisecond access, but significantly cheaper
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }
  }

  # Rule 2: Clean up old versions
  # When versioning is on, overwriting a file keeps the old version.
  # We don't need old versions forever — 30 days is enough to catch mistakes.
  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    filter {} # applies to entire bucket

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Rule 3: Abort incomplete multipart uploads
  # If a large file upload fails halfway, it leaves orphaned parts in S3.
  # This cleans them up after 7 days.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {} # applies to entire bucket

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}


# ─── Bucket Policy ───
# Enforce that all uploads use encryption.
# If someone (or some script) tries to upload without encryption
# headers, the upload is denied.

resource "aws_s3_bucket_policy" "enforce_encryption" {
  bucket = aws_s3_bucket.data_archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.data_archive.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
          # Allow uploads that don't specify encryption header
          # because the bucket default encryption will apply automatically.
          # This condition only blocks explicit requests for OTHER encryption types.
          Null = {
            "s3:x-amz-server-side-encryption" = "false"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.data_archive.arn,
          "${aws_s3_bucket.data_archive.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
