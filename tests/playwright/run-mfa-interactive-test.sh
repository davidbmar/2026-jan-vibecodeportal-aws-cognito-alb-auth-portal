#!/bin/bash

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  🔐 INTERACTIVE MFA QR CODE TEST"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "This test will:"
echo "  1. Open a browser window"
echo "  2. Navigate to the portal"
echo "  3. Wait for you to LOG IN manually"
echo "  4. Navigate to Settings → MFA Setup"
echo "  5. Check if the QR code actually appears"
echo ""
echo "This will PROVE whether the QR code bug exists or not."
echo ""
echo "Press Ctrl+C to cancel, or press Enter to start..."
read

echo ""
echo "Starting test..."
echo ""

# Run the test in headed mode so user can see and interact
npx playwright test tests/mfa-interactive.spec.js --headed

echo ""
echo "Test complete!"
echo ""
echo "Check the screenshots:"
echo "  /tmp/mfa-settings-page.png   - Settings page"
echo "  /tmp/mfa-setup-page.png      - MFA setup page"
echo ""
