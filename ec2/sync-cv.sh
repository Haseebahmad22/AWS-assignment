#!/bin/bash
# ==============================================================================
# Script: sync-cv.sh
# Purpose: Synchronize CV files from S3 site/ prefix to Apache web root,
#          replace footer placeholder with EC2 instance ID obtained via IMDSv2,
#          and log operation status to /var/log/cv-sync.log.
# Author: Haseeb Ahmad (23L-3069)
# Lab 7: Host Your CV on AWS
# ==============================================================================

BUCKET="${BUCKET:-cv-23l-3069}"
WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/cv-sync.log"

# Ensure log directory/file exists
touch "${LOG_FILE}" 2>/dev/null || true

# Obtain IMDSv2 Token (IMDSv2 is strictly required)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

# If instance ID couldn't be fetched, fallback gracefully
if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID="unknown-instance"
fi

# Synchronize files from S3 site/ prefix to Apache web root
aws s3 sync "s3://${BUCKET}/site/" "${WEB_ROOT}/" --delete
SYNC_STATUS=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ $SYNC_STATUS -eq 0 ]; then
    # Replace placeholder with EC2 followed by the instance ID
    if [ -f "${WEB_ROOT}/index.html" ]; then
        sed -i "s/{{HOSTED_ON}}/EC2 ${INSTANCE_ID}/g" "${WEB_ROOT}/index.html"
    fi
    # Set proper permissions so web server can read files
    chmod 644 ${WEB_ROOT}/* 2>/dev/null || true
    echo "${TIMESTAMP} - SUCCESS: Synced s3://${BUCKET}/site/ to ${WEB_ROOT}. Configured EC2 ${INSTANCE_ID}" >> "${LOG_FILE}"
else
    echo "${TIMESTAMP} - ERROR: S3 sync failed with exit code ${SYNC_STATUS}" >> "${LOG_FILE}"
fi
