#!/bin/bash
# Deploy SMS MFA using the secure deployment role

set -e

ACCOUNT_ID="821850226835"
ROLE_NAME="employee-portal-deployer"
EXTERNAL_ID="employee-portal-deploy-2026"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║    Deploying SMS MFA with Secure Role                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Assume the deployment role
echo "🔐 Step 1/3: Assuming deployment role..."
echo "   Role: ${ROLE_NAME}"
echo ""

ASSUMED_ROLE=$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "terraform-sms-mfa-deploy-$(date +%Y%m%d%H%M%S)" \
  --external-id "${EXTERNAL_ID}" \
  --duration-seconds 3600 \
  --output json 2>&1)

if [ $? -ne 0 ]; then
  echo "❌ Failed to assume role!"
  echo ""
  echo "Error: $ASSUMED_ROLE"
  echo ""
  echo "Possible reasons:"
  echo "  • Role doesn't exist yet (run ./create_deployment_role.sh first)"
  echo "  • You don't have permission to assume this role"
  echo "  • External ID mismatch"
  echo ""
  exit 1
fi

# Extract credentials
export AWS_ACCESS_KEY_ID=$(echo $ASSUMED_ROLE | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $ASSUMED_ROLE | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $ASSUMED_ROLE | jq -r '.Credentials.SessionToken')

echo "✓ Role assumed successfully"
echo ""

# Step 2: Verify identity
echo "✅ Step 2/3: Verifying identity..."
IDENTITY=$(aws sts get-caller-identity --output json)
echo "   Acting as: $(echo $IDENTITY | jq -r '.Arn')"
echo ""

# Step 3: Deploy with Terraform
echo "🚀 Step 3/3: Deploying SMS MFA configuration..."
echo ""

cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Run terraform apply
terraform apply -auto-approve

if [ $? -eq 0 ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           ✅ SMS MFA DEPLOYMENT SUCCESSFUL!               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "✨ Changes Applied:"
  echo "   • Cognito MFA configuration: OPTIONAL (users choose)"
  echo "   • SMS MFA enabled via Amazon SNS"
  echo "   • Phone number schema added"
  echo "   • Users can now choose TOTP or SMS"
  echo ""
  echo "📋 Next Steps:"
  echo "   1. Users can configure SMS MFA during login"
  echo "   2. Phone numbers must be in E.164 format (+12025551234)"
  echo "   3. Monitor SMS costs in CloudWatch"
  echo ""
  echo "💡 Tip: Set SNS spending limit:"
  echo "   aws sns set-sms-attributes --attributes MonthlySpendLimit=10"
  echo ""
else
  echo ""
  echo "❌ Deployment failed!"
  echo ""
  echo "Check the error messages above."
  exit 1
fi

# Cleanup - unset credentials
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
