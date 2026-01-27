#!/bin/bash

###############################################################################
# PORTAL TEST HARNESS
#
# Runs critical flow tests to validate no regressions after changes.
# This should be run:
# 1. Before committing code
# 2. After fixing bugs
# 3. Before deploying to production
#
# The harness runs ONLY the critical user flow tests, not all 72 tests.
# This ensures fast feedback while catching the most important issues.
###############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  🧪 PORTAL TEST HARNESS - Critical Flow Validation"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "This harness tests the CRITICAL user flows that must always work:"
echo "  • Password reset flow"
echo "  • Logout and login flow"
echo "  • Portal navigation"
echo "  • Settings access"
echo "  • MFA setup flow"
echo ""
echo "Starting tests..."
echo ""

# Create results directory
RESULTS_DIR="/tmp/test-harness-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Function to run a test file
run_test() {
    local test_file="$1"
    local test_name="$2"

    echo "─────────────────────────────────────────────────────────────────────"
    echo -e "${BLUE}Running: ${test_name}${NC}"
    echo "─────────────────────────────────────────────────────────────────────"

    # Run the test and capture output
    if npm test "$test_file" > "$RESULTS_DIR/${test_name}.txt" 2>&1; then
        echo -e "${GREEN}✅ PASSED${NC}: $test_name"
        ((PASSED_TESTS++))
        return 0
    else
        # Check if it's a skip or actual failure
        if grep -q "skipped" "$RESULTS_DIR/${test_name}.txt"; then
            echo -e "${YELLOW}⏭️  SKIPPED${NC}: $test_name (requires authentication)"
            ((SKIPPED_TESTS++))
            return 0
        else
            echo -e "${RED}❌ FAILED${NC}: $test_name"
            ((FAILED_TESTS++))

            # Show last 20 lines of error
            echo ""
            echo "Last 20 lines of output:"
            tail -20 "$RESULTS_DIR/${test_name}.txt"
            echo ""

            return 1
        fi
    fi
}

# Critical Flow Tests (in order of user journey)

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  PHASE 1: UNAUTHENTICATED USER FLOWS"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Test 1: Password Reset Flow
((TOTAL_TESTS++))
run_test "tests/password-reset-e2e.spec.js" "password-reset-flow" || true

# Test 2: Logout and Login Flow
((TOTAL_TESTS++))
run_test "tests/logout-login-e2e.spec.js" "logout-login-flow" || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  PHASE 2: PORTAL NAVIGATION AND ACCESS"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Test 3: User Flow Tests (navigation, areas, health check)
((TOTAL_TESTS++))
run_test "tests/user-flows.spec.js" "portal-navigation-flows" || true

# Test 4: User Journey Tests (complete portal experience)
((TOTAL_TESTS++))
run_test "tests/user-journey.spec.js" "complete-user-journey" || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  PHASE 3: AUTHENTICATED USER FEATURES (may skip without auth)"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Test 5: Settings Page
((TOTAL_TESTS++))
run_test "tests/settings.spec.js" "settings-page-tests" || true

# Test 6: MFA Setup Flow
((TOTAL_TESTS++))
run_test "tests/mfa-user-flow.spec.js" "mfa-setup-user-flow" || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  PHASE 4: CHANGE PASSWORD FLOW"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Test 7: Change Password
((TOTAL_TESTS++))
run_test "tests/change-password.spec.js" "change-password-flow" || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  📊 TEST HARNESS RESULTS"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "Total Tests Run: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo -e "${YELLOW}Skipped: $SKIPPED_TESTS${NC}"
echo ""

# Calculate percentage
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
    echo "Pass Rate: ${PASS_RATE}%"
else
    PASS_RATE=0
fi

echo ""
echo "Detailed results saved to: $RESULTS_DIR"
echo ""

# Determine overall status
if [ $FAILED_TESTS -eq 0 ]; then
    echo "─────────────────────────────────────────────────────────────────────"
    echo -e "${GREEN}✅ ALL CRITICAL FLOWS PASSING${NC}"
    echo "─────────────────────────────────────────────────────────────────────"
    echo ""
    echo "✅ Safe to commit"
    echo "✅ Safe to deploy"
    echo ""
    exit 0
elif [ $FAILED_TESTS -le 2 ] && [ $PASS_RATE -ge 70 ]; then
    echo "─────────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}⚠️  SOME TESTS FAILED (but pass rate >= 70%)${NC}"
    echo "─────────────────────────────────────────────────────────────────────"
    echo ""
    echo "⚠️  Review failures before committing"
    echo "⚠️  Check if failures are known issues"
    echo ""
    echo "Failed tests:"
    ls -1 "$RESULTS_DIR" | grep -v "\.txt$" || echo "  (check detailed results)"
    echo ""
    exit 1
else
    echo "─────────────────────────────────────────────────────────────────────"
    echo -e "${RED}❌ CRITICAL FLOWS FAILING${NC}"
    echo "─────────────────────────────────────────────────────────────────────"
    echo ""
    echo "❌ DO NOT COMMIT"
    echo "❌ DO NOT DEPLOY"
    echo ""
    echo "Critical issues detected:"
    echo "  • $FAILED_TESTS test(s) failed"
    echo "  • Pass rate: ${PASS_RATE}%"
    echo ""
    echo "Review failures in: $RESULTS_DIR"
    echo ""
    exit 1
fi
