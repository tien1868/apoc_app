#!/usr/bin/env bash
set -euo pipefail

# ── APOC² Deploy Script ─────────────────────────────────────────────────────
# Builds Docker image, pushes to ECR, and deploys to AWS App Runner.
# Usage: ./deploy.sh
# Requires: AWS CLI v2, Docker, .env file with secrets

APP_NAME="apoc2"
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_CPU="1 vCPU"
INSTANCE_MEMORY="2 GB"
PORT=8080

# ── Load .env file (safe parser — only reads KEY=VALUE lines) ───────────────
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.example to .env and fill in values."
  exit 1
fi

# Only export well-formed KEY=VALUE lines, skip comments and malformed lines
while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank lines, comments, lines without =
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
  export "$line"
done < .env

# Provide defaults for optional vars
export EBAY_RUNAME="${EBAY_RUNAME:-}"
export ENVIRONMENT="${ENVIRONMENT:-production}"

echo "▸ Region: ${AWS_REGION}"

# ── Get AWS account ID ──────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_URI}/${APP_NAME}:latest"

echo "▸ Account: ${ACCOUNT_ID}"
echo "▸ Image:   ${IMAGE_URI}"

# ── Create ECR repository if it doesn't exist ──────────────────────────────
if ! aws ecr describe-repositories --repository-names "${APP_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "▸ Creating ECR repository: ${APP_NAME}"
  aws ecr create-repository \
    --repository-name "${APP_NAME}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --output text
else
  echo "▸ ECR repository exists: ${APP_NAME}"
fi

# ── Build and push Docker image ────────────────────────────────────────────
echo "▸ Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_URI}"

echo "▸ Building Docker image..."
docker build -t "${APP_NAME}:latest" .

echo "▸ Tagging and pushing to ECR..."
docker tag "${APP_NAME}:latest" "${IMAGE_URI}"
docker push "${IMAGE_URI}"

# ── Build environment variables JSON for App Runner ─────────────────────────
ENV_VARS=$(cat <<ENVJSON
{
  "AWS_ACCESS_KEY_ID": "${AWS_ACCESS_KEY_ID}",
  "AWS_SECRET_ACCESS_KEY": "${AWS_SECRET_ACCESS_KEY}",
  "AWS_REGION": "${AWS_REGION}",
  "EBAY_APP_ID": "${EBAY_APP_ID}",
  "EBAY_DEV_ID": "${EBAY_DEV_ID}",
  "EBAY_CERT_ID": "${EBAY_CERT_ID}",
  "EBAY_RUNAME": "${EBAY_RUNAME}",
  "ENVIRONMENT": "${ENVIRONMENT:-production}"
}
ENVJSON
)

# ── Create or get App Runner ECR access role ────────────────────────────────
ROLE_NAME="AppRunnerECRAccessRole-${APP_NAME}"
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "▸ Creating IAM role: ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "build.apprunner.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' --output text
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
  echo "▸ Waiting for role propagation..."
  sleep 10
fi
ACCESS_ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

# ── Create or update App Runner service ─────────────────────────────────────
SERVICE_ARN=$(aws apprunner list-services --region "${AWS_REGION}" \
  --query "ServiceSummaryList[?ServiceName=='${APP_NAME}'].ServiceArn | [0]" --output text 2>/dev/null || true)

SOURCE_CONFIG=$(cat <<SRCJSON
{
  "ImageRepository": {
    "ImageIdentifier": "${IMAGE_URI}",
    "ImageConfiguration": {
      "Port": "${PORT}",
      "RuntimeEnvironmentVariables": ${ENV_VARS}
    },
    "ImageRepositoryType": "ECR"
  },
  "AutoDeploymentsEnabled": false,
  "AuthenticationConfiguration": {
    "AccessRoleArn": "${ACCESS_ROLE_ARN}"
  }
}
SRCJSON
)

INSTANCE_CONFIG="{\"Cpu\":\"${INSTANCE_CPU}\",\"Memory\":\"${INSTANCE_MEMORY}\"}"

AUTO_SCALING_ARN=""
# Create auto-scaling config
EXISTING_AS=$(aws apprunner list-auto-scaling-configurations --region "${AWS_REGION}" \
  --query "AutoScalingConfigurationSummaryList[?AutoScalingConfigurationName=='${APP_NAME}-scaling'] | [0].AutoScalingConfigurationArn" \
  --output text 2>/dev/null || true)

if [ "${EXISTING_AS}" = "None" ] || [ -z "${EXISTING_AS}" ]; then
  echo "▸ Creating auto-scaling configuration..."
  AUTO_SCALING_ARN=$(aws apprunner create-auto-scaling-configuration \
    --auto-scaling-configuration-name "${APP_NAME}-scaling" \
    --max-concurrency 10 \
    --min-size 1 \
    --max-size 5 \
    --region "${AWS_REGION}" \
    --query 'AutoScalingConfiguration.AutoScalingConfigurationArn' --output text)
else
  AUTO_SCALING_ARN="${EXISTING_AS}"
  echo "▸ Using existing auto-scaling config: ${AUTO_SCALING_ARN}"
fi

HEALTH_CHECK='{"Protocol":"HTTP","Path":"/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":3}'

if [ "${SERVICE_ARN}" = "None" ] || [ -z "${SERVICE_ARN}" ]; then
  echo "▸ Creating App Runner service: ${APP_NAME}"
  SERVICE_ARN=$(aws apprunner create-service \
    --service-name "${APP_NAME}" \
    --source-configuration "${SOURCE_CONFIG}" \
    --instance-configuration "${INSTANCE_CONFIG}" \
    --auto-scaling-configuration-arn "${AUTO_SCALING_ARN}" \
    --health-check-configuration "${HEALTH_CHECK}" \
    --region "${AWS_REGION}" \
    --query 'Service.ServiceArn' --output text)
  echo "▸ Service created: ${SERVICE_ARN}"
else
  echo "▸ Updating existing App Runner service..."
  aws apprunner update-service \
    --service-arn "${SERVICE_ARN}" \
    --source-configuration "${SOURCE_CONFIG}" \
    --instance-configuration "${INSTANCE_CONFIG}" \
    --auto-scaling-configuration-arn "${AUTO_SCALING_ARN}" \
    --health-check-configuration "${HEALTH_CHECK}" \
    --region "${AWS_REGION}" \
    --output text
  echo "▸ Service update initiated: ${SERVICE_ARN}"
fi

# ── Wait for service to reach RUNNING status ────────────────────────────────
echo ""
echo "▸ Waiting for service to reach RUNNING status..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  STATUS=$(aws apprunner describe-service \
    --service-arn "${SERVICE_ARN}" \
    --region "${AWS_REGION}" \
    --query 'Service.Status' --output text)
  if [ "${STATUS}" = "RUNNING" ]; then
    break
  fi
  echo "  Status: ${STATUS} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [ "${STATUS}" != "RUNNING" ]; then
  echo "ERROR: Service did not reach RUNNING status within ${TIMEOUT}s (current: ${STATUS})"
  exit 1
fi

# ── Get service URL and run health check ────────────────────────────────────
SERVICE_URL=$(aws apprunner describe-service \
  --service-arn "${SERVICE_ARN}" \
  --region "${AWS_REGION}" \
  --query 'Service.ServiceUrl' --output text)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  APOC² deployed successfully!"
echo "  URL: https://${SERVICE_URL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Health check validation ─────────────────────────────────────────────────
echo "▸ Running health check..."
sleep 5  # brief pause for routing to stabilize

HEALTH_RESPONSE=$(curl -sf "https://${SERVICE_URL}/health" 2>&1) || {
  echo "ERROR: Health check failed — could not reach https://${SERVICE_URL}/health"
  exit 1
}

echo "${HEALTH_RESPONSE}" | python -m json.tool

# Validate response
HEALTH_STATUS=$(echo "${HEALTH_RESPONSE}" | python -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
if [ "${HEALTH_STATUS}" != "healthy" ]; then
  echo "ERROR: Health check returned status '${HEALTH_STATUS}' (expected 'healthy')"
  exit 1
fi

echo ""
echo "Health check passed."
