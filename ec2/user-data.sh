#!/bin/bash
# ==============================================================================
# Script: user-data.sh
# Purpose: Cloud-init bootstrap script for Amazon Linux 2023 EC2 instance.
#          Installs Apache (httpd), configures sync script, schedules it every 5 min
#          via systemd timer, and executes the initial sync.
# Author: Haseeb Ahmad (23L-3069)
# Lab 7: Host Your CV on AWS
# ==============================================================================

set -e

# Update and install Apache web server
dnf update -y
dnf install -y httpd

# Ensure Apache starts on boot and runs now
systemctl enable --now httpd

# Install the sync-cv script to /usr/local/bin
cat << 'EOF' > /usr/local/bin/sync-cv.sh
#!/bin/bash
BUCKET="cv-23l-3069"
WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/cv-sync.log"

touch "${LOG_FILE}" 2>/dev/null || true

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID="unknown-instance"
fi

aws s3 sync "s3://${BUCKET}/site/" "${WEB_ROOT}/" --delete
SYNC_STATUS=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ $SYNC_STATUS -eq 0 ]; then
    if [ -f "${WEB_ROOT}/index.html" ]; then
        sed -i "s/{{HOSTED_ON}}/EC2 ${INSTANCE_ID}/g" "${WEB_ROOT}/index.html"
    fi
    chmod 644 ${WEB_ROOT}/* 2>/dev/null || true
    echo "${TIMESTAMP} - SUCCESS: Synced s3://${BUCKET}/site/ to ${WEB_ROOT}. Configured EC2 ${INSTANCE_ID}" >> "${LOG_FILE}"
else
    echo "${TIMESTAMP} - ERROR: S3 sync failed with exit code ${SYNC_STATUS}" >> "${LOG_FILE}"
fi
EOF

chmod +x /usr/local/bin/sync-cv.sh

# Create Systemd Service for sync
cat << 'EOF' > /etc/systemd/system/cv-sync.service
[Unit]
Description=CV S3 Sync Service
After=network.target httpd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
StandardOutput=journal
StandardError=journal
EOF

# Create Systemd Timer to run every 5 minutes (native to Amazon Linux 2023)
cat << 'EOF' > /etc/systemd/system/cv-sync.timer
[Unit]
Description=Run CV S3 Sync every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload systemd, enable and start the timer
systemctl daemon-reload
systemctl enable --now cv-sync.timer

# Execute initial sync immediately
/usr/local/bin/sync-cv.sh
