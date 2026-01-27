#!/bin/bash

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  🔐 INTERACTIVE PASSWORD RESET TEST"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "This test will:"
echo "  1. Send a reset code to your email (dmar@capsule.com)"
echo "  2. PAUSE and wait for you to enter the code"
echo "  3. Complete the password reset"
echo "  4. Verify it worked"
echo ""
echo "Press Ctrl+C to cancel, or press Enter to start..."
read

echo ""
echo "Starting test..."
echo ""

# Set test email
export TEST_EMAIL="dmar@capsule.com"
export TEST_PASSWORD="NewTest123@"

# Run the test
npx playwright test tests/password-reset-interactive.spec.js --headed

echo ""
echo "Test complete!"
echo ""
