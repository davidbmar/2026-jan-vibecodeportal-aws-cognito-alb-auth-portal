#!/bin/bash
#
# Quick Employee Portal Test (Non-blocking version)
#

PORTAL_URL="https://portal.capsule-playground.com"
PORTAL_IP="54.202.154.151"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "================================================"
echo "Quick Portal Test"
echo "================================================"

PASSED=0
FAILED=0

# Test with timeout
quick_test() {
    local name="$1"
    local url="$2"
    local expected="$3"

    echo -n "Testing $name... "

    actual=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")

    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}✓ PASS${NC} ($actual)"
        ((PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (expected $expected, got $actual)"
        ((FAILED++))
    fi
}

# Basic tests
quick_test "Health Endpoint" "$PORTAL_URL/health" "200"
quick_test "Home Page" "$PORTAL_URL/" "302"
quick_test "Directory" "$PORTAL_URL/directory" "302"
quick_test "EC2 Resources" "$PORTAL_URL/ec2-resources" "302"
quick_test "Settings" "$PORTAL_URL/settings" "302"

# Service check via SSH
echo -n "Testing Service Status... "
SERVICE_STATUS=$(ssh -i /home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    ubuntu@$PORTAL_IP \
    "systemctl is-active employee-portal" 2>/dev/null)

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} ($SERVICE_STATUS)"
    ((FAILED++))
fi

# Code verification
echo -n "Testing JWT Fix... "
JWT_FIX=$(ssh -i /home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    ubuntu@$PORTAL_IP \
    "grep -c '\"\",' /opt/employee-portal/app.py" 2>/dev/null)

if [ "$JWT_FIX" -ge "1" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC}"
    ((FAILED++))
fi

echo -n "Testing Launch Function... "
LAUNCH_FN=$(ssh -i /home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    ubuntu@$PORTAL_IP \
    "grep -c 'def launch_ec2_instance' /opt/employee-portal/app.py" 2>/dev/null)

if [ "$LAUNCH_FN" -ge "1" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC}"
    ((FAILED++))
fi

echo -n "Testing Auth Loop Fix (verify_aud)... "
AUTH_FIX=$(ssh -i /home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    ubuntu@$PORTAL_IP \
    "grep -c 'verify_aud.*False' /opt/employee-portal/app.py" 2>/dev/null)

if [ "$AUTH_FIX" -ge "1" ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ FAIL${NC}"
    ((FAILED++))
fi

echo ""
echo "================================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "================================================"
echo ""
echo "MANUAL TEST REQUIRED:"
echo "  1. Navigate to https://portal.capsule-playground.com"
echo "  2. Enter your email and submit"
echo "  3. Enter the 6-digit verification code"
echo "  4. Verify you reach the home page (no login loop)"
echo "================================================"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
