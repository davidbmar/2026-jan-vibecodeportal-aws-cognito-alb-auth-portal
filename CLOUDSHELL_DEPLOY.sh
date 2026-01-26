#!/bin/bash
# Quick deployment script for AWS CloudShell
# Copy/paste this entire script into CloudShell

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║    Deploying SMS MFA from CloudShell                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Check if we're in the right account
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ "$ACCOUNT_ID" != "821850226835" ]; then
  echo "❌ Wrong AWS account! Expected 821850226835, got $ACCOUNT_ID"
  exit 1
fi
echo "✓ Correct AWS account: $ACCOUNT_ID"
echo ""

# Navigate to terraform directory
# Adjust this path based on where you copied the files
TERRAFORM_DIR="./cognito_alb_ec2/terraform/envs/tier5"

if [ ! -d "$TERRAFORM_DIR" ]; then
  echo "❌ Terraform directory not found: $TERRAFORM_DIR"
  echo ""
  echo "Please copy the terraform files to CloudShell first:"
  echo "  1. Download terraform directory from EC2 server"
  echo "  2. Upload to CloudShell: Actions → Upload file"
  echo "  3. Run this script again"
  exit 1
fi

cd "$TERRAFORM_DIR"
echo "✓ Found terraform directory"
echo ""

# Initialize terraform if needed
if [ ! -d ".terraform" ]; then
  echo "🔧 Initializing Terraform..."
  terraform init
  echo ""
fi

# Show what will change
echo "📋 Reviewing changes..."
terraform plan
echo ""

# Ask for confirmation
read -p "Apply these changes? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# Apply changes
echo ""
echo "🚀 Applying changes..."
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
  echo "   1. Deploy Settings UI page to portal"
  echo "   2. Users can configure their MFA preference"
  echo "   3. Monitor SMS costs in CloudWatch"
  echo ""
else
  echo ""
  echo "❌ Deployment failed! Check errors above."
  exit 1
fi
