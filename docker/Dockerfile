# ──────────────────────────────────────────────
# Docker Image for RDS pg_dump Export
# ──────────────────────────────────────────────
# This image contains:
#   - pg_dump (PostgreSQL 16 client) — to export data from RDS
#   - aws cli — to upload the dump file to S3
#   - export.sh — the script that orchestrates the export
#
# It does NOT contain a full PostgreSQL server.
# It's ~80MB total — small, fast to pull, fast to start.
#
# BUILD:
#   docker build -t rds-to-s3-export .
#
# TEST LOCALLY:
#   docker run \
#     -e PGHOST=your-rds-endpoint \
#     -e PGPORT=5432 \
#     -e PGDATABASE=your_db \
#     -e PGUSER=your_user \
#     -e PGPASSWORD=your_password \
#     -e TARGET_YEAR=2025 \
#     -e TARGET_MONTH=02 \
#     -e S3_BUCKET=marsquant-market-data-archive \
#     -e DRY_RUN=true \
#     rds-to-s3-export
# ──────────────────────────────────────────────

FROM alpine:3.19

# Install pg_dump (postgresql16-client) and aws cli
RUN apk add --no-cache \
    postgresql16-client \
    aws-cli \
    bash \
    gzip \
    coreutils \
    && rm -rf /var/cache/apk/*

# Copy the export script
COPY export.sh /usr/local/bin/export.sh
RUN chmod +x /usr/local/bin/export.sh

# Run as non-root for security
RUN adduser -D -s /bin/bash exporter
USER exporter
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/export.sh"]
