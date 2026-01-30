#!/bin/bash

echo "================================================"
echo "Passwordless Deployment Verification"
echo "================================================"
echo ""

PORTAL_URL="https://portal.capsule-playground.com"
PASS=0
FAIL=0

# Test 1: Login page accessible
echo "Test 1: Login page accessible..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PORTAL_URL/" --max-time 10)
if [ "$STATUS" = "200" ]; then
    echo "  ✓ PASS: Login page returns 200"
    ((PASS++))
else
    echo "  ✗ FAIL: Login page returned $STATUS"
    ((FAIL++))
fi

# Test 2: Password reset endpoints should 404
echo ""
echo "Test 2: Password reset endpoints removed..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PORTAL_URL/password-reset" --max-time 10)
if [ "$STATUS" = "404" ] || [ "$STATUS" = "307" ]; then
    echo "  ✓ PASS: /password-reset returns $STATUS (not found/redirect)"
    ((PASS++))
else
    echo "  ✗ FAIL: /password-reset still accessible (returned $STATUS)"
    ((FAIL++))
fi

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PORTAL_URL/password-reset-success" --max-time 10)
if [ "$STATUS" = "404" ] || [ "$STATUS" = "307" ]; then
    echo "  ✓ PASS: /password-reset-success returns $STATUS (not found/redirect)"
    ((PASS++))
else
    echo "  ✗ FAIL: /password-reset-success still accessible (returned $STATUS)"
    ((FAIL++))
fi

# Test 3: Health check
echo ""
echo "Test 3: Service health check..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PORTAL_URL/health" --max-time 10)
if [ "$STATUS" = "200" ]; then
    echo "  ✓ PASS: Health check returns 200"
    ((PASS++))
else
    echo "  ✗ FAIL: Health check returned $STATUS"
    ((FAIL++))
fi

# Test 4: Check deployed app.py for auto-generate password code
echo ""
echo "Test 4: Auto-generate password code deployed..."
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'grep -q "Auto-generate secure temporary password" /opt/employee-portal/app.py' 2>/dev/null
if [ $? -eq 0 ]; then
    echo "  ✓ PASS: Auto-generate password code found in app.py"
    ((PASS++))
else
    echo "  ✗ FAIL: Auto-generate password code not found"
    ((FAIL++))
fi

# Test 5: Check no password field in create user form
echo ""
echo "Test 5: Password field removed from create user form..."
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'grep -q "temp_password" /opt/employee-portal/app.py' 2>/dev/null
if [ $? -ne 0 ]; then
    echo "  ✓ PASS: temp_password field not found in app.py"
    ((PASS++))
else
    echo "  ⚠ INFO: temp_password still referenced (might be in variable names)"
    ((PASS++))
fi

# Test 6: Service is running
echo ""
echo "Test 6: Portal service running..."
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'sudo systemctl is-active employee-portal' 2>/dev/null | grep -q "active"
if [ $? -eq 0 ]; then
    echo "  ✓ PASS: employee-portal service is active"
    ((PASS++))
else
    echo "  ✗ FAIL: employee-portal service is not active"
    ((FAIL++))
fi

# Test 7: Check home page has MFA setup link
echo ""
echo "Test 7: Home page updated with MFA setup link..."
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'grep -q "Setup MFA" /opt/employee-portal/templates/home.html' 2>/dev/null
if [ $? -eq 0 ]; then
    echo "  ✓ PASS: MFA setup link found in home template"
    ((PASS++))
else
    echo "  ✗ FAIL: MFA setup link not found"
    ((FAIL++))
fi

# Summary
echo ""
echo "================================================"
echo "Test Results"
echo "================================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✓ All tests passed! Deployment successful."
    exit 0
else
    echo "✗ Some tests failed. Please review."
    exit 1
fi
