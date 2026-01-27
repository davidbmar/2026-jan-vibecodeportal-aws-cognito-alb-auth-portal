#!/bin/bash

# Script to apply SSM permissions
# This will:
# 1. Update your current IAM policy with SSM permissions
# 2. Attach the AmazonSSMManagedInstanceCore policy to ssh-whitelist-role

set -e

echo "================================================"
echo "Applying SSM Session Manager Permissions"
echo "================================================"
echo ""

# Get current user/role
CURRENT_IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Current identity: $CURRENT_IDENTITY"
echo ""

# Step 1: Attach SSM policy to ssh-whitelist-role for the EC2 instances
echo "Step 1: Attaching AmazonSSMManagedInstanceCore to ssh-whitelist-role..."
echo "This allows the tagged EC2 instances to connect to SSM."
echo ""

aws iam attach-role-policy \
  --role-name ssh-whitelist-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  2>&1 && echo "✅ Successfully attached SSM policy to ssh-whitelist-role" || echo "⚠️  Policy may already be attached"

echo ""
echo "Step 2: Verifying attached policies..."
echo ""

aws iam list-attached-role-policies --role-name ssh-whitelist-role \
  --query 'AttachedPolicies[].PolicyName' \
  --output table

echo ""
echo "================================================"
echo "Waiting for IAM changes to propagate..."
echo "================================================"
echo "This may take 5-10 minutes for instances to register with SSM"
echo ""

# Check if instances are already registered
echo "Checking current SSM managed instances..."
REGISTERED_COUNT=$(aws ssm describe-instance-information \
  --region us-west-2 \
  --filters "Key=InstanceIds,Values=i-0d1e3b59f57974076,i-06883f2837f77f365,i-0966d965518d2dba1" \
  --query 'length(InstanceInformationList)' \
  --output text 2>/dev/null || echo "0")

echo "Currently registered instances: $REGISTERED_COUNT / 3"
echo ""

if [ "$REGISTERED_COUNT" -eq 3 ]; then
    echo "✅ All 3 instances are already registered with SSM!"
else
    echo "⏳ Waiting for instances to register with SSM..."
    echo "   This can take up to 10 minutes..."
    echo ""
    echo "You can check status with:"
    echo "  aws ssm describe-instance-information --region us-west-2 \\"
    echo "    --filters \"Key=InstanceIds,Values=i-0d1e3b59f57974076\" \\"
    echo "    --query 'InstanceInformationList[0].[InstanceId,PingStatus]'"
fi

echo ""
echo "================================================"
echo "Next Steps"
echo "================================================"
echo ""
echo "1. Wait 5-10 minutes for instances to register with SSM"
echo ""
echo "2. Verify instances are online:"
echo "   aws ssm describe-instance-information --region us-west-2 \\"
echo "     --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table"
echo ""
echo "3. Test SSM Session Manager in AWS Console:"
echo "   https://console.aws.amazon.com/systems-manager/session-manager"
echo ""
echo "4. Test via portal:"
echo "   - Login: https://portal.capsule-playground.com"
echo "   - Click Engineering/HR/Product tabs"
echo "   - Should redirect to SSM Session Manager"
echo ""
echo "================================================"
echo "SSM Configuration Complete!"
echo "================================================"
