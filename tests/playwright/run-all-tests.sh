#!/bin/bash

# Complete Test Suite Runner
# Runs ALL portal tests and generates summary report

echo "════════════════════════════════════════════════════════════"
echo "  EMPLOYEE PORTAL - COMPLETE TEST SUITE"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Running all automated tests..."
echo ""

# Run tests and capture output
npm test 2>&1 | tee /tmp/complete-test-run-$(date +%Y%m%d-%H%M%S).txt

# Extract summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  TEST SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo ""

# Show last 30 lines which contain the summary
tail -30 /tmp/complete-test-run-$(date +%Y%m%d-%H%M%S).txt | grep -E "passed|failed|skipped|flaky"

echo ""
echo "Full results saved to: /tmp/complete-test-run-$(date +%Y%m%d-%H%M%S).txt"
echo ""
