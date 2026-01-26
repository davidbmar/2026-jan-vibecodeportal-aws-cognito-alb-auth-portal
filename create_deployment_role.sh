#!/bin/bash
# Create Deployment Role with Scoped PassRole Permission
# This role is secure and follows AWS best practices

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║    Creating Secure Deployment Role                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

ACCOUNT_ID="821850226835"
REGION="us-east-1"
ROLE_NAME="employee-portal-deployer"

# Step 1: Create Trust Policy
echo "📝 Step 1/4: Creating trust policy..."
cat > /tmp/trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::821850226835:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "employee-portal-deploy-2026"
        }
      }
    }
  ]
}
EOF
echo "✓ Trust policy created"
echo ""

# Step 2: Create Permissions Policy
echo "📝 Step 2/4: Creating permissions policy..."
cat > /tmp/deployment-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CognitoUserPoolManagement",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:UpdateUserPool",
        "cognito-idp:DescribeUserPool",
        "cognito-idp:GetUserPool",
        "cognito-idp:ListUserPools"
      ],
      "Resource": "arn:aws:cognito-idp:${REGION}:${ACCOUNT_ID}:userpool/us-east-1_kF4pcrUVF"
    },
    {
      "Sid": "IAMRoleManagementForCognitoSMS",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:TagRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/employee-portal-cognito-sms-role"
    },
    {
      "Sid": "ScopedPassRoleForCognitoOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/employee-portal-cognito-sms-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cognito-idp.amazonaws.com"
        }
      }
    },
    {
      "Sid": "ExplicitDenyPassRoleToOtherServices",
      "Effect": "Deny",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/employee-portal-cognito-sms-role",
      "Condition": {
        "StringNotEquals": {
          "iam:PassedToService": "cognito-idp.amazonaws.com"
        }
      }
    },
    {
      "Sid": "TerraformStateRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::terraform-state-*/*",
        "arn:aws:s3:::terraform-state-*"
      ]
    }
  ]
}
EOF
echo "✓ Permissions policy created"
echo ""

# Step 3: Create IAM Role
echo "🔐 Step 3/4: Creating IAM role..."
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Deployment role for employee portal with scoped PassRole" \
  --tags Key=Project,Value=employee-portal Key=Purpose,Value=deployment \
  --region "${REGION}" \
  2>&1

if [ $? -eq 0 ]; then
  echo "✓ Role created: ${ROLE_NAME}"
else
  echo "⚠️  Role might already exist, continuing..."
fi
echo ""

# Step 4: Attach Permissions Policy
echo "📎 Step 4/4: Attaching permissions policy..."
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "CognitoSMSDeployment" \
  --policy-document file:///tmp/deployment-policy.json \
  --region "${REGION}" \
  2>&1

if [ $? -eq 0 ]; then
  echo "✓ Policy attached"
else
  echo "❌ Failed to attach policy"
  exit 1
fi
echo ""

# Cleanup temp files
rm -f /tmp/trust-policy.json /tmp/deployment-policy.json

echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ✅ DEPLOYMENT ROLE CREATED!                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Role Details:"
echo "   Name: ${ROLE_NAME}"
echo "   ARN:  arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "🔒 Security Features:"
echo "   ✅ Scoped to specific Cognito User Pool only"
echo "   ✅ Scoped to specific IAM role only"
echo "   ✅ PassRole restricted to Cognito service"
echo "   ✅ Explicit deny for other services"
echo "   ✅ External ID required (prevents confused deputy)"
echo ""
echo "📖 Next Steps:"
echo ""
echo "1. Assume the role:"
echo "   aws sts assume-role \\"
echo "     --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME} \\"
echo "     --role-session-name terraform-deploy \\"
echo "     --external-id employee-portal-deploy-2026"
echo ""
echo "2. Export credentials (from assume-role output):"
echo "   export AWS_ACCESS_KEY_ID=<AccessKeyId>"
echo "   export AWS_SECRET_ACCESS_KEY=<SecretAccessKey>"
echo "   export AWS_SESSION_TOKEN=<SessionToken>"
echo ""
echo "3. Deploy SMS MFA:"
echo "   cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5"
echo "   terraform apply"
echo ""
echo "💡 Or use the helper script: ./deploy_with_role.sh"
echo ""
