#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Employee Access Portal Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Change to terraform directory
cd "$(dirname "$0")/../terraform/envs/tier5"

# Initialize Terraform
echo -e "${YELLOW}Initializing Terraform...${NC}"
terraform init

# Plan
echo ""
echo -e "${YELLOW}Creating Terraform plan...${NC}"
terraform plan -out=tfplan

# Apply
echo ""
echo -e "${YELLOW}Applying Terraform configuration...${NC}"
terraform apply tfplan

# Get outputs
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}ALB DNS Name:${NC}"
terraform output -raw alb_dns_name
echo ""
echo ""

echo -e "${BLUE}Cognito User Pool ID:${NC}"
terraform output -raw cognito_user_pool_id
echo ""
echo ""

echo -e "${BLUE}Cognito App Client ID:${NC}"
terraform output -raw cognito_app_client_id
echo ""
echo ""

echo -e "${BLUE}Cognito Domain:${NC}"
terraform output -raw cognito_domain
echo ""
echo ""

echo -e "${BLUE}Example URLs:${NC}"
terraform output -json example_urls | jq -r 'to_entries[] | "  \(.key): \(.value)"'
echo ""
echo ""

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "1. Wait 2-3 minutes for the EC2 instance to fully initialize"
echo ""
echo "2. Set passwords for users with these commands:"
echo ""
terraform output -raw user_password_commands
echo ""
echo ""
echo "3. Access the portal at:"
echo "   http://$(terraform output -raw alb_dns_name)/"
echo ""
echo -e "${GREEN}Done!${NC}"
