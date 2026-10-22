#!/usr/bin/env bash
# ==============================================================================
# Master Deployment Script for AWS CloudShell (Lab 7)
# Candidate: Haseeb Ahmad (23L-3069)
# Region: us-east-1 (or detected session region)
# ==============================================================================

set -e

ROLL="23l-3069"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
BUCKET="cv-${ROLL}"
EC2_NAME="cv-ec2-${ROLL}"
EC2_ROLE="cv-ec2-role-${ROLL}"
LAMBDA_NAME="cv-func-${ROLL}"
LAMBDA_ROLE="cv-lambda-role-${ROLL}"
SG_NAME="cv-sg-${ROLL}"

echo "=========================================================="
echo " Starting Full Lab 7 AWS Deployment for Roll: ${ROLL}"
echo " Region: ${REGION} | Bucket: ${BUCKET}"
echo "=========================================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "[1/7] Verified AWS Account ID: ${ACCOUNT_ID}"

# 1. Create S3 Bucket & Configure
echo "[2/7] Creating S3 Bucket ${BUCKET}..."
if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null || echo "Bucket may already exist"
else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}" 2>/dev/null || echo "Bucket may already exist"
fi

aws s3api put-bucket-tagging --bucket "${BUCKET}" --tagging 'TagSet=[{Key=Owner,Value=23l-3069},{Key=Course,Value=cloud}]'
aws s3api put-public-access-block --bucket "${BUCKET}" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-versioning --bucket "${BUCKET}" --versioning-configuration Status=Enabled

echo "Uploading CV site files to s3://${BUCKET}/site/..."
aws s3 cp site/index.html "s3://${BUCKET}/site/index.html"
aws s3 cp site/style.css "s3://${BUCKET}/site/style.css"
aws s3 cp site/cv.pdf "s3://${BUCKET}/site/cv.pdf"

# 2. Create IAM Roles
echo "[3/7] Setting up IAM Roles..."
# EC2 Role
aws iam create-role --role-name "${EC2_ROLE}" --assume-role-policy-document file://iam/ec2-trust-policy.json --tags 'Key=Owner,Value=23l-3069' 'Key=Course,Value=cloud' 2>/dev/null || true
aws iam put-role-policy --role-name "${EC2_ROLE}" --policy-name "cv-ec2-permissions" --policy-document file://iam/ec2-permission-policy.json

aws iam create-instance-profile --instance-profile-name "${EC2_ROLE}" 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name "${EC2_ROLE}" --role-name "${EC2_ROLE}" 2>/dev/null || true

# Lambda Role
aws iam create-role --role-name "${LAMBDA_ROLE}" --assume-role-policy-document file://iam/lambda-trust-policy.json --tags 'Key=Owner,Value=23l-3069' 'Key=Course,Value=cloud' 2>/dev/null || true
aws iam attach-role-policy --role-name "${LAMBDA_ROLE}" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
aws iam put-role-policy --role-name "${LAMBDA_ROLE}" --policy-name "cv-lambda-permissions" --policy-document file://iam/lambda-permission-policy.json

echo "Sleeping 10s for IAM propagation..."
sleep 10

# 3. Security Group
echo "[4/7] Setting up Security Group..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group --group-name "${SG_NAME}" --description "Security group for CV EC2" --vpc-id "${VPC_ID}" --query "GroupId" --output text)
    aws ec2 create-tags --resources "${SG_ID}" --tags "Key=Owner,Value=23l-3069" "Key=Course,Value=cloud" "Key=Name,Value=${SG_NAME}"
    # Inbound port 80 open to all
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0
fi

# 4. EC2 Instance Launch
echo "[5/7] Launching EC2 Instance (Amazon Linux 2023, IMDSv2 required)..."
AMI_ID=$(aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" --query "Parameter.Value" --output text)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type t2.micro \
    --iam-instance-profile Name="${EC2_ROLE}" \
    --security-group-ids "${SG_ID}" \
    --user-data file://ec2/user-data.sh \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Owner,Value=23l-3069},{Key=Course,Value=cloud},{Key=Name,Value=${EC2_NAME}}]" \
    --query "Instances[0].InstanceId" --output text)

echo "EC2 Instance launched: ${INSTANCE_ID}"

# 5. Lambda Function Deployment
echo "[6/7] Deploying Lambda Function ${LAMBDA_NAME}..."
rm -f /tmp/lambda_function.zip
(cd lambda && zip /tmp/lambda_function.zip lambda_function.py)

aws lambda create-function \
    --function-name "${LAMBDA_NAME}" \
    --runtime python3.12 \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb:///tmp/lambda_function.zip \
    --timeout 10 \
    --memory-size 128 \
    --environment "Variables={BUCKET=${BUCKET},PREFIX=site/}" \
    --tags "Owner=23l-3069,Course=cloud" 2>/dev/null || \
aws lambda update-function-code \
    --function-name "${LAMBDA_NAME}" \
    --zip-file fileb:///tmp/lambda_function.zip

echo "Configuring Function URL (Auth: NONE)..."
LAMBDA_URL=$(aws lambda get-function-url-config --function-name "${LAMBDA_NAME}" --query "FunctionUrl" --output text 2>/dev/null || \
aws lambda create-function-url-config --function-name "${LAMBDA_NAME}" --auth-type NONE --query "FunctionUrl" --output text)

aws lambda add-permission \
    --function-name "${LAMBDA_NAME}" \
    --statement-id FunctionURLAllowPublicAccess \
    --action lambda:InvokeFunctionUrl \
    --principal "*" \
    --function-url-auth-type NONE 2>/dev/null || true

# Set log retention to 7 days
aws logs put-retention-policy --log-group-name "/aws/lambda/${LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true

# 6. Retrieve Endpoint Information
echo "[7/7] Retrieving public addresses..."
echo "Waiting for EC2 public IP..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
EC2_IP=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "=========================================================="
echo " DEPLOYMENT COMPLETE!"
echo " S3 Bucket:        s3://${BUCKET}"
echo " EC2 Web Address:  http://${EC2_IP}"
echo " Lambda Address:   ${LAMBDA_URL}"
echo "=========================================================="
echo "Next step: Run the evidence collection script:"
echo "./collect-evidence.sh ${BUCKET} ${EC2_IP} ${LAMBDA_URL}"
