#!/bin/bash
# Run change password tests after portal is ready

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Change Password Fix - Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Wait for portal to be ready
echo "⏳ Checking if portal is ready..."
max_attempts=20
attempt=1

while [ $attempt -le $max_attempts ]; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" https://portal.capsule-playground.com/health 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        echo "✅ Portal is ready!"
        echo ""
        break
    fi

    echo "   Attempt $attempt/$max_attempts: HTTP $http_code (waiting 30s...)"

    if [ $attempt -eq $max_attempts ]; then
        echo ""
        echo "❌ Portal did not come up after $max_attempts attempts"
        exit 1
    fi

    sleep 30
    attempt=$((attempt + 1))
done

# Quick verification of the fix
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Quick Fix Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Testing /logout-and-reset endpoint..."
response=$(curl -s -L -w "\n%{url_effective}" https://portal.capsule-playground.com/logout-and-reset 2>&1)
final_url=$(echo "$response" | tail -1)

echo "   Final URL: $final_url"

if [[ "$final_url" == *"/password-reset"* ]]; then
    echo "   ✅ Redirects to /password-reset (FIX WORKS!)"
elif [[ "$final_url" == *"cognito"* ]]; then
    echo "   ℹ️  Redirects to Cognito login (auth required - expected)"
else
    echo "   ⚠️  Unexpected redirect: $final_url"
fi

echo ""

# Run Playwright tests
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎭 Running Playwright Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd /home/ubuntu/cognito_alb_ec2/tests/playwright

# Test 1: Change password fix verification
echo "Test 1: Change Password Fix Verification"
echo "─────────────────────────────────────────"
npm test tests/change-password-fixed.spec.js 2>&1 | tee /tmp/change-password-test-results.txt
test1_result=${PIPESTATUS[0]}
echo ""

# Test 2: Password reset flow (should still work)
echo "Test 2: Password Reset Flow"
echo "─────────────────────────────────────────"
npm test tests/password-reset.spec.js 2>&1 | tee /tmp/password-reset-test-results.txt
test2_result=${PIPESTATUS[0]}
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Results Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $test1_result -eq 0 ]; then
    echo "✅ Change Password Fix Tests: PASSED"
else
    echo "❌ Change Password Fix Tests: FAILED"
fi

if [ $test2_result -eq 0 ]; then
    echo "✅ Password Reset Tests: PASSED"
else
    echo "❌ Password Reset Tests: FAILED"
fi

echo ""

if [ $test1_result -eq 0 ] && [ $test2_result -eq 0 ]; then
    echo "🎉 ALL TESTS PASSED! Fix is working!"
    echo ""
    echo "✅ You can now:"
    echo "   1. Go to: https://portal.capsule-playground.com/settings"
    echo "   2. Click: 🔑 CHANGE PASSWORD"
    echo "   3. Should redirect to /password-reset (no error!)"
    exit 0
else
    echo "⚠️  Some tests failed. Review output above."
    exit 1
fi
