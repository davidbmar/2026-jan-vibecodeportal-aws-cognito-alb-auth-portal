#!/bin/bash

###################################################################################
# Email MFA Deployment Script with IAM Policy Creation
#
# This script:
# 1. Creates a new managed IAM policy for email MFA resources
# 2. Attaches the policy to the ssh-whitelist-role
# 3. Deploys the email MFA infrastructure via Terraform
#
# Usage: ./deploy-email-mfa-with-permissions.sh
###################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
POLICY_NAME="email-mfa-deployment-policy"
ROLE_NAME="ssh-whitelist-role"
POLICY_FILE="iam-email-mfa-policy.json"
AWS_REGION="us-west-2"
ACCOUNT_ID="821850226835"

echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Email MFA Infrastructure Deployment${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

# Step 1: Check if policy file exists
echo -e "${BLUE}Step 1: Checking policy file...${NC}"
if [ ! -f "$POLICY_FILE" ]; then
    echo -e "${RED}❌ Policy file not found: $POLICY_FILE${NC}"
    echo -e "${YELLOW}Please ensure you're running this from terraform/envs/tier5/${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Policy file found${NC}\n"

# Step 2: Validate JSON
echo -e "${BLUE}Step 2: Validating JSON...${NC}"
if ! jq empty "$POLICY_FILE" 2>/dev/null; then
    echo -e "${RED}❌ Invalid JSON in policy file${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JSON is valid${NC}\n"

# Step 3: Check policy size
POLICY_SIZE=$(wc -c < "$POLICY_FILE")
echo -e "${BLUE}Step 3: Checking policy size...${NC}"
echo -e "  Policy size: ${POLICY_SIZE} bytes (max: 6144 bytes)"
if [ "$POLICY_SIZE" -gt 6144 ]; then
    echo -e "${RED}❌ Policy exceeds 6144 character limit${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Policy size is within limits${NC}\n"

# Step 4: Check if policy already exists
echo -e "${BLUE}Step 4: Checking for existing policy...${NC}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Policy already exists${NC}"
    echo -e "  Policy ARN: ${POLICY_ARN}"

    # Get current version
    CURRENT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
    echo -e "  Current version: ${CURRENT_VERSION}"

    read -p "Do you want to create a new version? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}Creating new policy version...${NC}"

        # List all versions to potentially delete old ones
        VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions | length(@)' --output text)

        if [ "$VERSION_COUNT" -ge 5 ]; then
            echo -e "${YELLOW}⚠️  Policy has 5 versions (AWS limit). Deleting oldest non-default version...${NC}"
            OLDEST_VERSION=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
                --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate) | [0].VersionId' \
                --output text)

            if [ "$OLDEST_VERSION" != "None" ]; then
                aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_VERSION"
                echo -e "${GREEN}✅ Deleted old version: ${OLDEST_VERSION}${NC}"
            fi
        fi

        # Create new version and set as default
        NEW_VERSION=$(aws iam create-policy-version \
            --policy-arn "$POLICY_ARN" \
            --policy-document file://"$POLICY_FILE" \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)

        echo -e "${GREEN}✅ Created new policy version: ${NEW_VERSION}${NC}\n"
    else
        echo -e "${YELLOW}Skipping policy update${NC}\n"
    fi
else
    # Create new policy
    echo -e "${BLUE}Creating new IAM policy: ${POLICY_NAME}${NC}"

    CREATE_OUTPUT=$(aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://"$POLICY_FILE" \
        --description "Permissions for email MFA infrastructure deployment (DynamoDB, SES, Lambda)" \
        --region "$AWS_REGION" 2>&1)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Policy created successfully${NC}"
        echo -e "  Policy ARN: ${POLICY_ARN}\n"
    else
        echo -e "${RED}❌ Failed to create policy:${NC}"
        echo "$CREATE_OUTPUT"
        exit 1
    fi
fi

# Step 5: Attach policy to role
echo -e "${BLUE}Step 5: Attaching policy to role...${NC}"
echo -e "  Role: ${ROLE_NAME}"
echo -e "  Policy: ${POLICY_NAME}"

# Check if already attached
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" | grep -q "$POLICY_ARN"; then
    echo -e "${GREEN}✅ Policy already attached to role${NC}\n"
else
    ATTACH_OUTPUT=$(aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN" 2>&1)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Policy attached successfully${NC}\n"
    else
        echo -e "${RED}❌ Failed to attach policy:${NC}"
        echo "$ATTACH_OUTPUT"
        exit 1
    fi
fi

# Step 6: Wait for IAM propagation
echo -e "${BLUE}Step 6: Waiting for IAM changes to propagate...${NC}"
echo -e "${YELLOW}  (Sleeping 10 seconds for IAM eventual consistency)${NC}"
sleep 10
echo -e "${GREEN}✅ Ready to proceed${NC}\n"

# Step 7: Deploy infrastructure with Terraform
echo -e "${BLUE}Step 7: Deploying infrastructure with Terraform...${NC}\n"

# Initialize Terraform
echo -e "${BLUE}Initializing Terraform...${NC}"
terraform init -upgrade

# Validate
echo -e "\n${BLUE}Validating Terraform configuration...${NC}"
terraform validate

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Terraform validation failed${NC}"
    exit 1
fi

# Plan
echo -e "\n${BLUE}Generating Terraform plan...${NC}"
terraform plan -out=tfplan-email-mfa

# Show what will be created
echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Resources to be created:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "  - DynamoDB Table: employee-portal-mfa-codes"
echo -e "  - Lambda: employee-portal-define-auth-challenge"
echo -e "  - Lambda: employee-portal-create-auth-challenge"
echo -e "  - Lambda: employee-portal-verify-auth-challenge"
echo -e "  - IAM Role: employee-portal-mfa-lambda-role"
echo -e "  - SES Email Identity: noreply@capsule-playground.com"
echo -e "  - Cognito User Pool: Updated with Lambda triggers"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

# Ask for confirmation
read -p "Deploy infrastructure? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deployment cancelled${NC}"
    exit 0
fi

# Apply
echo -e "\n${BLUE}Applying Terraform changes...${NC}\n"
terraform apply tfplan-email-mfa

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Infrastructure deployed successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}\n"
else
    echo -e "\n${RED}❌ Terraform apply failed${NC}"
    exit 1
fi

# Step 8: Post-deployment verification
echo -e "${BLUE}Step 8: Post-deployment verification...${NC}\n"

# Check DynamoDB
echo -e "${BLUE}Checking DynamoDB table...${NC}"
if aws dynamodb describe-table --table-name employee-portal-mfa-codes --region "$AWS_REGION" &>/dev/null; then
    echo -e "${GREEN}✅ DynamoDB table created${NC}"
else
    echo -e "${YELLOW}⚠️  DynamoDB table not found (may still be creating)${NC}"
fi

# Check Lambda functions
echo -e "\n${BLUE}Checking Lambda functions...${NC}"
for func in define-auth-challenge create-auth-challenge verify-auth-challenge; do
    if aws lambda get-function --function-name "employee-portal-${func}" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${GREEN}✅ Lambda function: employee-portal-${func}${NC}"
    else
        echo -e "${YELLOW}⚠️  Lambda function not found: employee-portal-${func}${NC}"
    fi
done

# Check SES
echo -e "\n${BLUE}Checking SES email identity...${NC}"
SES_STATUS=$(aws ses get-identity-verification-attributes \
    --identities noreply@capsule-playground.com \
    --region "$AWS_REGION" \
    --query 'VerificationAttributes."noreply@capsule-playground.com".VerificationStatus' \
    --output text 2>/dev/null || echo "NOT_FOUND")

echo -e "  Email: noreply@capsule-playground.com"
echo -e "  Status: ${SES_STATUS}"

if [ "$SES_STATUS" = "Pending" ]; then
    echo -e "${YELLOW}⚠️  Email verification pending${NC}"
    echo -e "${YELLOW}   Check inbox and click verification link${NC}"
elif [ "$SES_STATUS" = "Success" ]; then
    echo -e "${GREEN}✅ Email verified${NC}"
else
    echo -e "${YELLOW}⚠️  Email identity created but needs verification${NC}"
fi

# Check Cognito Lambda triggers
echo -e "\n${BLUE}Checking Cognito Lambda triggers...${NC}"
LAMBDA_CONFIG=$(aws cognito-idp describe-user-pool \
    --user-pool-id us-west-2_WePThH2J8 \
    --region "$AWS_REGION" \
    --query 'UserPool.LambdaConfig' 2>/dev/null)

if echo "$LAMBDA_CONFIG" | grep -q "DefineAuthChallenge"; then
    echo -e "${GREEN}✅ Lambda triggers configured in Cognito${NC}"
else
    echo -e "${YELLOW}⚠️  Lambda triggers may not be configured${NC}"
fi

# Step 9: Next steps
echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}📋 NEXT STEPS${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

echo -e "1. ${YELLOW}Verify SES Email (if pending):${NC}"
echo -e "   Check inbox for: noreply@capsule-playground.com"
echo -e "   Click verification link in email from AWS\n"

echo -e "2. ${YELLOW}Run Tests:${NC}"
echo -e "   cd /home/ubuntu/cognito_alb_ec2"
echo -e "   ./tests/run-email-mfa-tests.sh all\n"

echo -e "3. ${YELLOW}Manual Verification:${NC}"
echo -e "   - Test login at: https://portal.capsule-playground.com"
echo -e "   - Check Lambda logs:"
echo -e "     aws logs tail /aws/lambda/employee-portal-create-auth-challenge --since 10m\n"
echo -e "   - Check DynamoDB:"
echo -e "     aws dynamodb scan --table-name employee-portal-mfa-codes\n"

echo -e "4. ${YELLOW}View CloudWatch Logs:${NC}"
echo -e "   https://console.aws.amazon.com/cloudwatch/home?region=us-west-2#logsV2:log-groups\n"

echo -e "${GREEN}✅ Deployment complete!${NC}\n"
