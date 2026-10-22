#!/usr/bin/env bash
# ==============================================================================
# Script: collect-evidence.sh
# Purpose: Gathers all compliance and verification evidence for AWS Lab 7.
# Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
# Output: evidence.txt
# Author: Haseeb Ahmad (23L-3069)
# ==============================================================================

export AWS_PAGER=""

# Section 7 & Check C14: Must take exactly 3 arguments. If not, print usage and exit with 1.
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
    exit 1
fi

BUCKET="$1"
EC2_ADDR="$2"
LAMBDA_ADDR="$3"
OUTPUT_FILE="evidence.txt"

# Normalize URLs (add scheme if omitted)
if [[ ! "$EC2_ADDR" =~ ^https?:// ]]; then
    EC2_URL="http://${EC2_ADDR}"
else
    EC2_URL="${EC2_ADDR}"
fi

if [[ ! "$LAMBDA_ADDR" =~ ^https?:// ]]; then
    LAMBDA_URL="https://${LAMBDA_ADDR}"
else
    LAMBDA_URL="${LAMBDA_ADDR}"
fi

# Trim trailing slash
EC2_URL="${EC2_URL%/}"
LAMBDA_URL="${LAMBDA_URL%/}"

EC2_ROLE="cv-ec2-role-23l-3069"
LAMBDA_ROLE="cv-lambda-role-23l-3069"
LAMBDA_FUNC="cv-func-23l-3069"
SG_NAME="cv-sg-23l-3069"

# Clear or initialize output file
> "${OUTPUT_FILE}"

# Helper function to execute and log sections with error tolerance
log_section() {
    local section_name="$1"
    echo "== ${section_name} ==" >> "${OUTPUT_FILE}"
}

# 1. caller
log_section "caller"
if ! aws sts get-caller-identity --output json >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to execute aws sts get-caller-identity]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 2. public-access
log_section "public-access"
if ! aws s3api get-public-access-block --bucket "${BUCKET}" --output json >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to get public access block for bucket ${BUCKET}]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 3. versioning
log_section "versioning"
if ! aws s3api get-bucket-versioning --bucket "${BUCKET}" --output json >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to get bucket versioning for ${BUCKET}]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 4. objects
log_section "objects"
if ! aws s3 ls "s3://${BUCKET}/site/" >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to list s3://${BUCKET}/site/]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 5. ec2-policy
log_section "ec2-policy"
EC2_POLICIES=$(aws iam list-role-policies --role-name "${EC2_ROLE}" --query "PolicyNames[]" --output text 2>/dev/null)
if [ -n "$EC2_POLICIES" ]; then
    for p in $EC2_POLICIES; do
        aws iam get-role-policy --role-name "${EC2_ROLE}" --policy-name "$p" --output json >> "${OUTPUT_FILE}" 2>&1 || true
    done
else
    # Fallback to direct name if list query failed
    aws iam get-role-policy --role-name "${EC2_ROLE}" --policy-name "cv-ec2-permissions" --output json >> "${OUTPUT_FILE}" 2>&1 || \
    echo "[Error: Failed to retrieve inline policy for ${EC2_ROLE}]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 6. lambda-policy
log_section "lambda-policy"
echo "-- Attached Managed Policies --" >> "${OUTPUT_FILE}"
aws iam list-attached-role-policies --role-name "${LAMBDA_ROLE}" --output json >> "${OUTPUT_FILE}" 2>&1 || \
echo "[Error: Failed to list attached policies for ${LAMBDA_ROLE}]" >> "${OUTPUT_FILE}"

echo "-- Inline Role Policies --" >> "${OUTPUT_FILE}"
LAMBDA_POLICIES=$(aws iam list-role-policies --role-name "${LAMBDA_ROLE}" --query "PolicyNames[]" --output text 2>/dev/null)
if [ -n "$LAMBDA_POLICIES" ]; then
    for p in $LAMBDA_POLICIES; do
        aws iam get-role-policy --role-name "${LAMBDA_ROLE}" --policy-name "$p" --output json >> "${OUTPUT_FILE}" 2>&1 || true
    done
else
    aws iam get-role-policy --role-name "${LAMBDA_ROLE}" --policy-name "cv-lambda-permissions" --output json >> "${OUTPUT_FILE}" 2>&1 || \
    echo "[Error: Failed to retrieve inline policy for ${LAMBDA_ROLE}]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 7. security-group
log_section "security-group"
if ! aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[].IpPermissions" --output json >> "${OUTPUT_FILE}" 2>&1; then
    # Fallback to describe all SGs for instance if named filter returned error
    aws ec2 describe-security-groups --output json >> "${OUTPUT_FILE}" 2>&1 || \
    echo "[Error: Failed to describe security group]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 8. instance
log_section "instance"
if ! aws ec2 describe-instances --filters "Name=tag:Name,Values=cv-ec2-23l-3069" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[][InstanceId,InstanceType,MetadataOptions.HttpTokens,IamInstanceProfile.Arn]" --output json >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to query EC2 instance attributes]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 9. endpoints
log_section "endpoints"
echo "Testing EC2 endpoint:" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${EC2_URL}/" >> "${OUTPUT_FILE}" 2>&1 || echo "  EC2 / failed" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${EC2_URL}/style.css" >> "${OUTPUT_FILE}" 2>&1 || echo "  EC2 /style.css failed" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${EC2_URL}/cv.pdf" >> "${OUTPUT_FILE}" 2>&1 || echo "  EC2 /cv.pdf failed" >> "${OUTPUT_FILE}"

echo "Testing Lambda endpoint:" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${LAMBDA_URL}/" >> "${OUTPUT_FILE}" 2>&1 || echo "  Lambda / failed" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${LAMBDA_URL}/style.css" >> "${OUTPUT_FILE}" 2>&1 || echo "  Lambda /style.css failed" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${LAMBDA_URL}/cv.pdf" >> "${OUTPUT_FILE}" 2>&1 || echo "  Lambda /cv.pdf failed" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "${LAMBDA_URL}/anything" >> "${OUTPUT_FILE}" 2>&1 || echo "  Lambda /anything failed" >> "${OUTPUT_FILE}"

echo "Testing direct S3 endpoint (must be AccessDenied):" >> "${OUTPUT_FILE}"
curl -s -o /dev/null -w "  GET %{url_effective} -> HTTP %{http_code}, Content-Type: %{content_type}\n" "https://${BUCKET}.s3.amazonaws.com/site/index.html" >> "${OUTPUT_FILE}" 2>&1 || echo "  Direct S3 request failed" >> "${OUTPUT_FILE}"
echo "" >> "${OUTPUT_FILE}"

# 10. lambda-logs
log_section "lambda-logs"
if ! aws logs tail "/aws/lambda/${LAMBDA_FUNC}" --since 15m >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to fetch CloudWatch logs for /aws/lambda/${LAMBDA_FUNC}]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# 11. log-retention
log_section "log-retention"
if ! aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${LAMBDA_FUNC}" --query "logGroups[][logGroupName,retentionInDays]" --output json >> "${OUTPUT_FILE}" 2>&1; then
    echo "[Error: Failed to describe log groups]" >> "${OUTPUT_FILE}"
fi
echo "" >> "${OUTPUT_FILE}"

# Final output required by Section 7
echo "DONE"
