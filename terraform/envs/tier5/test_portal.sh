#!/bin/bash
#
# Employee Portal Test Harness
# Tests all portal endpoints and functionality
#

set -e

PORTAL_URL="https://portal.capsule-playground.com"
PORTAL_IP="54.202.154.151"
PORTAL_PRIVATE_IP="10.0.1.250"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================================"
echo "Employee Portal Test Harness"
echo "================================================"
echo "Target: $PORTAL_URL"
echo "Started: $(date)"
echo ""

PASSED=0
FAILED=0

# Test function
test_endpoint() {
    local name="$1"
    local url="$2"
    local expected_status="$3"
    local description="$4"

    echo -n "Testing: $name... "

    actual_status=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 "$url" 2>/dev/null || echo "000")

    if [ "$actual_status" = "$expected_status" ]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP $actual_status)"
        ((PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (Expected $expected_status, got $actual_status)"
        echo "  Description: $description"
        ((FAILED++))
    fi
}

# Test function with SSH
test_ssh_endpoint() {
    local name="$1"
    local command="$2"
    local expected_pattern="$3"

    echo -n "Testing: $name... "

    result=$(ssh -i /home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem -o StrictHostKeyChecking=no ubuntu@$PORTAL_IP "$command" 2>&1)

    if echo "$result" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "  Expected pattern: $expected_pattern"
        echo "  Got: ${result:0:100}"
        ((FAILED++))
    fi
}

echo "═══════════════════════════════════════════════"
echo "1. PUBLIC ENDPOINTS (Unauthenticated)"
echo "═══════════════════════════════════════════════"

test_endpoint "Health Check" \
    "$PORTAL_URL/health" \
    "200" \
    "Should return JSON health status"

test_endpoint "Home Page (Unauthenticated)" \
    "$PORTAL_URL/" \
    "302" \
    "Should redirect to Cognito login"

test_endpoint "Directory (Unauthenticated)" \
    "$PORTAL_URL/directory" \
    "302" \
    "Should redirect to Cognito login"

test_endpoint "EC2 Resources (Unauthenticated)" \
    "$PORTAL_URL/ec2-resources" \
    "302" \
    "Should redirect to Cognito login"

test_endpoint "Settings (Unauthenticated)" \
    "$PORTAL_URL/settings" \
    "302" \
    "Should redirect to Cognito login"

test_endpoint "Admin Panel (Unauthenticated)" \
    "$PORTAL_URL/admin" \
    "302" \
    "Should redirect to Cognito login"

echo ""
echo "═══════════════════════════════════════════════"
echo "2. API ENDPOINTS (Should Return JSON)"
echo "═══════════════════════════════════════════════"

test_endpoint "API: EC2 Instances" \
    "$PORTAL_URL/api/ec2/instances" \
    "302" \
    "Should redirect without auth token"

test_endpoint "API: Users List" \
    "$PORTAL_URL/api/users/list" \
    "302" \
    "Should redirect without auth token"

echo ""
echo "═══════════════════════════════════════════════"
echo "3. SERVICE STATUS"
echo "═══════════════════════════════════════════════"

test_ssh_endpoint "Service Running" \
    "systemctl is-active employee-portal" \
    "active"

test_ssh_endpoint "Service Enabled" \
    "systemctl is-enabled employee-portal" \
    "enabled"

test_ssh_endpoint "No Service Errors" \
    "sudo journalctl -u employee-portal --no-pager -n 50 | grep -i error | wc -l" \
    "^0$"

test_ssh_endpoint "Process Listening on Port 8000" \
    "ss -tlnp | grep :8000" \
    "LISTEN"

echo ""
echo "═══════════════════════════════════════════════"
echo "4. APPLICATION CODE VERIFICATION"
echo "═══════════════════════════════════════════════"

test_ssh_endpoint "JWT Decode Fix Present" \
    "grep -A 2 'jwt.decode' /opt/employee-portal/app.py | grep '\"\",' | wc -l" \
    "^1$"

test_ssh_endpoint "EC2 Launch Function Exists" \
    "grep -c 'def launch_ec2_instance' /opt/employee-portal/app.py" \
    "^2$"

test_ssh_endpoint "EC2 Launch API Endpoint" \
    "grep -c '/api/ec2/launch-instance' /opt/employee-portal/app.py" \
    "^1$"

test_ssh_endpoint "Launch Instance Modal HTML" \
    "grep -c 'LAUNCH NEW EC2 INSTANCE' /opt/employee-portal/app.py" \
    "^1$"

echo ""
echo "═══════════════════════════════════════════════"
echo "5. INFRASTRUCTURE CHECKS"
echo "═══════════════════════════════════════════════"

echo -n "Testing: Portal Instance Running... "
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids i-01ebe3bbad23c0efc --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
if [ "$INSTANCE_STATE" = "running" ]; then
    echo -e "${GREEN}✓ PASS${NC} (State: $INSTANCE_STATE)"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (State: $INSTANCE_STATE)"
    ((FAILED++))
fi

echo -n "Testing: ALB Health Check... "
ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null)
ALB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" 2>/dev/null || echo "000")
if [ "$ALB_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ PASS${NC} (HTTP $ALB_STATUS)"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (HTTP $ALB_STATUS)"
    ((FAILED++))
fi

echo -n "Testing: Security Group for Launched Instances... "
SG_EXISTS=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=vibecode-launched-instances-ssh" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [ "$SG_EXISTS" != "None" ] && [ -n "$SG_EXISTS" ]; then
    echo -e "${GREEN}✓ PASS${NC} (SG: $SG_EXISTS)"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠ SKIP${NC} (SG not created yet - normal if no instances launched)"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "6. DNS AND SSL"
echo "═══════════════════════════════════════════════"

echo -n "Testing: DNS Resolution... "
DNS_IP=$(dig +short portal.capsule-playground.com | tail -1)
if [ -n "$DNS_IP" ]; then
    echo -e "${GREEN}✓ PASS${NC} (Resolves to $DNS_IP)"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (DNS not resolving)"
    ((FAILED++))
fi

echo -n "Testing: SSL Certificate... "
SSL_EXPIRY=$(echo | openssl s_client -servername portal.capsule-playground.com -connect portal.capsule-playground.com:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$SSL_EXPIRY" ]; then
    echo -e "${GREEN}✓ PASS${NC} (Expires: $SSL_EXPIRY)"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (SSL certificate issue)"
    ((FAILED++))
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "TEST SUMMARY"
echo "═══════════════════════════════════════════════"
TOTAL=$((PASSED + FAILED))
echo "Total Tests: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
else
    echo -e "${GREEN}Failed: $FAILED${NC}"
fi

PASS_RATE=$((PASSED * 100 / TOTAL))
echo "Pass Rate: $PASS_RATE%"
echo ""
echo "Completed: $(date)"
echo "================================================"

if [ $FAILED -gt 0 ]; then
    exit 1
else
    exit 0
fi
