#!/bin/bash

# Test Authentication Flow - Monitor Lambda Logs
# This script watches all three Lambda function logs in real-time
# while you test the authentication flow in your browser.

echo "=========================================="
echo "Authentication Flow Test Monitor"
echo "=========================================="
echo ""
echo "This will watch CloudWatch logs for:"
echo "  1. DefineAuthChallenge (auth flow control)"
echo "  2. CreateAuthChallenge (code generation)"
echo "  3. VerifyAuthChallenge (code validation)"
echo ""
echo "INSTRUCTIONS:"
echo "  1. Leave this script running"
echo "  2. Open browser to: https://portal.capsule-playground.com"
echo "  3. Login with: dmar@capsule.com"
echo "  4. Watch the logs below for detailed output"
echo ""
echo "Press Ctrl+C to stop monitoring"
echo ""
echo "=========================================="
echo "Starting log monitoring..."
echo "=========================================="
echo ""

# Function to watch logs with label
watch_logs() {
    local function_name=$1
    local label=$2

    echo ""
    echo "--- $label ---"
    aws logs tail "/aws/lambda/$function_name" \
        --since 5s \
        --region us-west-2 \
        --format short \
        --follow 2>&1 | while read line; do
        echo "[$label] $line"
    done
}

# Watch all three Lambda functions in parallel
(watch_logs "employee-portal-define-auth-challenge" "DEFINE") &
DEFINE_PID=$!

(watch_logs "employee-portal-create-auth-challenge" "CREATE") &
CREATE_PID=$!

(watch_logs "employee-portal-verify-auth-challenge" "VERIFY") &
VERIFY_PID=$!

# Trap Ctrl+C to cleanup background processes
trap "echo ''; echo 'Stopping log monitoring...'; kill $DEFINE_PID $CREATE_PID $VERIFY_PID 2>/dev/null; exit 0" INT

# Wait for processes
wait
