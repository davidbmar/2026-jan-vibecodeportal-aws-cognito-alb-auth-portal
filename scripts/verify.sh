#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Verifying Employee Portal Deployment${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

cd "$(dirname "$0")/../terraform/envs/tier5"

# Check if Terraform state exists
if [ ! -f "terraform.tfstate" ]; then
    echo -e "${RED}✗ Terraform state not found. Run ./scripts/deploy.sh first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Terraform state found${NC}"

# Get outputs
echo ""
echo -e "${YELLOW}Getting deployment outputs...${NC}"
ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null)
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null)

if [ -z "$ALB_DNS" ] || [ -z "$USER_POOL_ID" ]; then
    echo -e "${RED}✗ Could not retrieve outputs. Check Terraform state.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ ALB DNS: $ALB_DNS${NC}"
echo -e "${GREEN}✓ User Pool ID: $USER_POOL_ID${NC}"

# Test health endpoint (should work without auth)
echo ""
echo -e "${YELLOW}Testing health endpoint (no auth)...${NC}"
HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" --max-time 10)

if [ "$HEALTH_RESPONSE" == "200" ]; then
    echo -e "${GREEN}✓ Health check passed (HTTP 200)${NC}"
else
    echo -e "${RED}✗ Health check failed (HTTP $HEALTH_RESPONSE)${NC}"
    echo "  This might mean:"
    echo "  - EC2 instance is still initializing (wait 2-3 minutes)"
    echo "  - Application failed to start"
    echo "  - Target group unhealthy"
fi

# Check if authenticated endpoint redirects to Cognito
echo ""
echo -e "${YELLOW}Testing authentication (should redirect to Cognito)...${NC}"
AUTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirects 0 "http://$ALB_DNS/" --max-time 10)

if [ "$AUTH_RESPONSE" == "302" ] || [ "$AUTH_RESPONSE" == "301" ]; then
    echo -e "${GREEN}✓ Authentication redirect working (HTTP $AUTH_RESPONSE)${NC}"
else
    echo -e "${YELLOW}⚠ Unexpected response (HTTP $AUTH_RESPONSE)${NC}"
fi

# Check Cognito users
echo ""
echo -e "${YELLOW}Checking Cognito users...${NC}"

USERS=("dmar@capsule.com" "jahn@capsule.com" "ahatcher@capsule.com" "peter@capsule.com" "sdedakia@capsule.com")

for USER in "${USERS[@]}"; do
    STATUS=$(aws cognito-idp admin-get-user \
        --user-pool-id $USER_POOL_ID \
        --username $USER \
        --query 'UserStatus' \
        --output text 2>/dev/null)

    if [ "$STATUS" == "CONFIRMED" ]; then
        echo -e "${GREEN}✓ $USER: CONFIRMED (password set)${NC}"
    elif [ "$STATUS" == "FORCE_CHANGE_PASSWORD" ]; then
        echo -e "${YELLOW}⚠ $USER: FORCE_CHANGE_PASSWORD (needs password)${NC}"
    else
        echo -e "${RED}✗ $USER: $STATUS${NC}"
    fi
done

# Summary
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Summary${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "Portal URL: http://$ALB_DNS/"
echo ""
echo "If health check passed but users need passwords, run:"
echo ""
echo "  cd terraform/envs/tier5"
echo "  terraform output user_password_commands"
echo ""
echo -e "${GREEN}Verification complete!${NC}"
