#!/bin/bash
#
# IP Whitelist Implementation Verification Script
# Tests the dynamic IP whitelisting feature after deployment
#

set -e

echo "=========================================="
echo "IP WHITELIST VERIFICATION SCRIPT"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Check security group exists and has correct description
echo "Test 1: Verify security group configuration"
echo "-------------------------------------------"

SG_INFO=$(aws ec2 describe-security-groups \
  --group-names vibecode-launched-instances \
  --query 'SecurityGroups[0].[GroupId,Description]' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$SG_INFO" = "NOT_FOUND" ]; then
  echo -e "${YELLOW}⚠ vibecode-launched-instances security group not found (not yet created)${NC}"
  echo "  This is normal if no instances have been launched yet."
  echo ""
else
  SG_ID=$(echo "$SG_INFO" | awk '{print $1}')
  SG_DESC=$(echo "$SG_INFO" | cut -f2-)
  echo -e "${GREEN}✓ Security group found: $SG_ID${NC}"
  echo "  Description: $SG_DESC"

  # Check for 0.0.0.0/0 rules on ports 80/443
  echo ""
  echo "  Checking for 0.0.0.0/0 rules on ports 80/443..."

  OPEN_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` || FromPort==`443`].IpRanges[?CidrIp==`0.0.0.0/0`]' \
    --output json)

  if [ "$OPEN_RULES" = "[]" ] || [ "$OPEN_RULES" = "null" ]; then
    echo -e "${GREEN}✓ No 0.0.0.0/0 rules found on ports 80/443 (correct!)${NC}"
  else
    echo -e "${RED}✗ Found 0.0.0.0/0 rules on ports 80/443 (should be removed!)${NC}"
    echo "  Rules: $OPEN_RULES"
  fi

  # Check for SSH rule
  echo ""
  echo "  Checking for SSH rule (port 22)..."

  SSH_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[*].CidrIp' \
    --output json)

  if [ "$SSH_RULES" != "[]" ] && [ "$SSH_RULES" != "null" ]; then
    echo -e "${GREEN}✓ SSH rule found (expected)${NC}"
    echo "  SSH allowed from: $SSH_RULES"
  else
    echo -e "${YELLOW}⚠ No SSH rule found${NC}"
  fi

  # Count dynamic IP whitelist rules
  echo ""
  echo "  Checking for dynamic IP whitelist rules..."

  WHITELIST_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[*].IpRanges[?contains(Description, `User:`)]' \
    --output json | jq -r 'flatten | length')

  echo -e "${GREEN}✓ Found $WHITELIST_RULES dynamic IP whitelist rules${NC}"

  if [ "$WHITELIST_RULES" -gt 0 ]; then
    echo ""
    echo "  Sample rules:"
    aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissions[*].IpRanges[?contains(Description, `User:`)].[CidrIp,Description]' \
      --output text | head -5 | while IFS=$'\t' read -r cidr desc; do
        echo "    - $cidr: $desc"
      done
  fi
fi

echo ""
echo ""

# Test 2: Check user_data.sh for required functions
echo "Test 2: Verify code functions exist"
echo "------------------------------------"

USER_DATA_FILE="user_data.sh"

if [ ! -f "$USER_DATA_FILE" ]; then
  echo -e "${RED}✗ user_data.sh not found in current directory${NC}"
  echo "  Please run this script from: terraform/envs/tier5/"
  exit 1
fi

echo "Checking for IP whitelist functions..."

FUNCTIONS=(
  "get_user_whitelisted_ip"
  "add_ip_to_security_group"
  "remove_ip_from_security_group"
  "get_instances_for_user_groups"
  "whitelist_user_ip_on_instances"
  "remove_user_ip_from_instances"
)

ALL_FOUND=true
for func in "${FUNCTIONS[@]}"; do
  if grep -q "^def $func" "$USER_DATA_FILE"; then
    echo -e "${GREEN}✓ Function found: $func${NC}"
  else
    echo -e "${RED}✗ Function missing: $func${NC}"
    ALL_FOUND=false
  fi
done

echo ""
echo "Checking for login hook integration..."

if grep -q "whitelist_user_ip_on_instances(email, user_groups, client_ip)" "$USER_DATA_FILE"; then
  echo -e "${GREEN}✓ Login hook integration found${NC}"
else
  echo -e "${RED}✗ Login hook integration missing${NC}"
  ALL_FOUND=false
fi

echo ""
echo "Checking for admin API endpoints..."

ENDPOINTS=(
  "/admin/ip-whitelist-audit"
  "/admin/cleanup-user-ip"
  "/admin/cleanup-orphaned-ips"
)

for endpoint in "${ENDPOINTS[@]}"; do
  if grep -q "\"$endpoint\"" "$USER_DATA_FILE"; then
    echo -e "${GREEN}✓ Endpoint found: $endpoint${NC}"
  else
    echo -e "${RED}✗ Endpoint missing: $endpoint${NC}"
    ALL_FOUND=false
  fi
done

echo ""
echo "Checking for admin UI components..."

if grep -q "AUDIT IP WHITELIST" "$USER_DATA_FILE"; then
  echo -e "${GREEN}✓ Admin UI section found${NC}"
else
  echo -e "${RED}✗ Admin UI section missing${NC}"
  ALL_FOUND=false
fi

if grep -q "function auditIPWhitelist()" "$USER_DATA_FILE"; then
  echo -e "${GREEN}✓ JavaScript functions found${NC}"
else
  echo -e "${RED}✗ JavaScript functions missing${NC}"
  ALL_FOUND=false
fi

echo ""
echo ""

# Test 3: Check for removed 0.0.0.0/0 rules in code
echo "Test 3: Verify 0.0.0.0/0 rules removed from code"
echo "------------------------------------------------"

# Check if there are any remaining 0.0.0.0/0 rules for ports 80/443 in the security group creation
HTTP_RULE_COUNT=$(grep -c "0.0.0.0/0.*80" "$USER_DATA_FILE" || true)
HTTPS_RULE_COUNT=$(grep -c "0.0.0.0/0.*443" "$USER_DATA_FILE" || true)

if [ "$HTTP_RULE_COUNT" -eq 0 ] && [ "$HTTPS_RULE_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✓ No 0.0.0.0/0 rules for ports 80/443 in code${NC}"
else
  echo -e "${YELLOW}⚠ Found references to 0.0.0.0/0 for ports 80/443${NC}"
  echo "  HTTP references: $HTTP_RULE_COUNT"
  echo "  HTTPS references: $HTTPS_RULE_COUNT"
  echo "  (May be in comments or documentation)"
fi

# Check security group description
if grep -q "HTTP/HTTPS dynamically whitelisted" "$USER_DATA_FILE"; then
  echo -e "${GREEN}✓ Security group description updated${NC}"
else
  echo -e "${YELLOW}⚠ Security group description not updated${NC}"
fi

echo ""
echo ""

# Summary
echo "=========================================="
echo "VERIFICATION SUMMARY"
echo "=========================================="

if [ "$ALL_FOUND" = true ]; then
  echo -e "${GREEN}✓ All code components verified!${NC}"
else
  echo -e "${RED}✗ Some code components missing or incorrect${NC}"
fi

echo ""
echo "Next steps:"
echo "1. Deploy the updated user_data.sh to portal EC2 instance"
echo "2. Login as test user and check CloudWatch Logs for [IP-WHITELIST] messages"
echo "3. Verify security group rules are created with descriptive descriptions"
echo "4. Test admin panel IP Whitelist Management section"
echo "5. Test IP replacement by logging in from different IP"
echo ""
echo "For detailed testing instructions, see:"
echo "  IP_WHITELIST_IMPLEMENTATION.md - Testing Instructions section"
echo ""
