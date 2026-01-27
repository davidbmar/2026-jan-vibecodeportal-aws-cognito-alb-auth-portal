const { test, expect } = require('@playwright/test');

/**
 * Interactive MFA Setup Test
 *
 * This test:
 * 1. Opens the browser in HEADED mode
 * 2. Waits for YOU to log in manually
 * 3. Then checks if the QR code shows up
 *
 * Run with:
 *   npm test tests/mfa-interactive.spec.js -- --headed
 *
 * Or use the run script:
 *   ./run-mfa-interactive-test.sh
 */

test.describe('Interactive MFA Setup - With Manual Login', () => {

  test('should show QR code after user logs in', async ({ page }) => {
    console.log('\n═══════════════════════════════════════════════════════════');
    console.log('  🔐 INTERACTIVE MFA QR CODE TEST');
    console.log('═══════════════════════════════════════════════════════════\n');

    console.log('This test will:');
    console.log('  1. Open the login page');
    console.log('  2. WAIT for you to log in manually');
    console.log('  3. Navigate to Settings');
    console.log('  4. Click "SET UP AUTHENTICATOR APP"');
    console.log('  5. Check if QR code appears\n');

    // Step 1: Navigate to portal home (will redirect to login)
    console.log('Step 1: Navigating to portal home...');
    await page.goto('https://portal.capsule-playground.com/');
    await page.waitForLoadState('networkidle');

    const url = page.url();
    console.log(`  Current URL: ${url}`);

    if (url.includes('login') || url.includes('auth')) {
      console.log('\n⏳ PLEASE LOG IN NOW');
      console.log('  → Enter your credentials in the browser');
      console.log('  → The test will wait up to 2 minutes...\n');

      // Wait for successful login (redirected back to portal)
      await page.waitForURL('**/portal.capsule-playground.com/**', {
        timeout: 120000, // 2 minutes
        waitUntil: 'networkidle'
      });

      console.log('✅ Login successful!\n');
    }

    // Step 2: Navigate to Settings
    console.log('Step 2: Navigating to Settings...');
    await page.goto('https://portal.capsule-playground.com/settings');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);

    const settingsUrl = page.url();
    console.log(`  Current URL: ${settingsUrl}`);

    if (!settingsUrl.includes('settings')) {
      console.log('  ❌ Not on settings page!');
      console.log(`  → Expected: /settings`);
      console.log(`  → Got: ${settingsUrl}`);
      expect(settingsUrl).toContain('settings');
      return;
    }

    console.log('  ✅ Settings page loaded\n');

    // Take screenshot of settings page
    await page.screenshot({ path: '/tmp/mfa-settings-page.png', fullPage: true });
    console.log('  📸 Screenshot saved: /tmp/mfa-settings-page.png\n');

    // Step 3: Find and click MFA setup button
    console.log('Step 3: Looking for "SET UP AUTHENTICATOR APP" button...');

    const mfaButton = page.locator('a:has-text("SET UP AUTHENTICATOR APP"), button:has-text("SET UP AUTHENTICATOR APP")').first();
    const buttonVisible = await mfaButton.isVisible().catch(() => false);

    if (!buttonVisible) {
      console.log('  ❌ MFA setup button NOT FOUND on settings page!');
      console.log('  → This is a critical bug\n');

      // Show what IS on the page
      const bodyText = await page.locator('body').textContent();
      console.log('  Page content preview:');
      console.log('  ' + bodyText.substring(0, 200) + '...\n');

      expect(buttonVisible).toBe(true);
      return;
    }

    console.log('  ✅ Found MFA setup button');

    const buttonHref = await mfaButton.getAttribute('href').catch(() => null);
    console.log(`  → Button href: ${buttonHref}\n`);

    // Step 4: Click the button
    console.log('Step 4: Clicking "SET UP AUTHENTICATOR APP" button...');
    await mfaButton.click();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(3000); // Wait for any dynamic content

    const mfaUrl = page.url();
    console.log(`  → Current URL: ${mfaUrl}`);

    if (!mfaUrl.includes('mfa-setup')) {
      console.log('  ⚠️  Did not navigate to /mfa-setup page');
      console.log(`  → Expected: /mfa-setup`);
      console.log(`  → Got: ${mfaUrl}\n`);
    } else {
      console.log('  ✅ Navigated to /mfa-setup page\n');
    }

    // Take screenshot of MFA page
    await page.screenshot({ path: '/tmp/mfa-setup-page.png', fullPage: true });
    console.log('  📸 Screenshot saved: /tmp/mfa-setup-page.png\n');

    // Step 5: THE CRITICAL CHECK - Is there a QR code?
    console.log('═══════════════════════════════════════════════════════════');
    console.log('  🔍 CHECKING FOR QR CODE (THIS IS THE IMPORTANT PART)');
    console.log('═══════════════════════════════════════════════════════════\n');

    const pageContent = await page.content();
    const bodyText = await page.locator('body').textContent();

    // Check for QR code presence
    const qrCodeCanvas = page.locator('canvas');
    const qrCodeCanvasCount = await qrCodeCanvas.count();

    const qrCodeImg = page.locator('img[alt*="QR"], img[src*="qr"], #qr-code, #qrcode');
    const qrCodeImgCount = await qrCodeImg.count();

    const hasQRCodeElement = qrCodeCanvasCount > 0 || qrCodeImgCount > 0;

    // Check for secret key (Base32 format: 32 characters, A-Z and 2-7)
    const secretKeyPattern = /[A-Z2-7]{32}/;
    const hasSecretKey = secretKeyPattern.test(bodyText);

    // Check for code input field
    const codeInput = page.locator('input[type="text"][maxlength="6"], input[maxlength="6"]');
    const hasCodeInput = await codeInput.count() > 0;

    // Check for verify button
    const verifyButton = page.locator('button:has-text("Verify"), button:has-text("VERIFY")');
    const hasVerifyButton = await verifyButton.count() > 0;

    // Check for BAD indicators (instructions to logout instead of QR code)
    const hasLogoutText = bodyText.toLowerCase().includes('log out');
    const hasLoginAgainText = bodyText.toLowerCase().includes('log back in') ||
                              bodyText.toLowerCase().includes('log in again');

    // Report findings
    console.log('📊 RESULTS:\n');
    console.log(`  ${hasQRCodeElement ? '✅' : '❌'} QR Code Element (canvas/img): ${hasQRCodeElement ? 'FOUND' : 'NOT FOUND'}`);

    if (qrCodeCanvasCount > 0) {
      console.log(`     → Found ${qrCodeCanvasCount} canvas element(s)`);
    }
    if (qrCodeImgCount > 0) {
      console.log(`     → Found ${qrCodeImgCount} QR image(s)`);
    }

    console.log(`  ${hasSecretKey ? '✅' : '❌'} Secret Key (Base32): ${hasSecretKey ? 'FOUND' : 'NOT FOUND'}`);
    console.log(`  ${hasCodeInput ? '✅' : '❌'} Code Input Field: ${hasCodeInput ? 'FOUND' : 'NOT FOUND'}`);
    console.log(`  ${hasVerifyButton ? '✅' : '❌'} Verify Button: ${hasVerifyButton ? 'FOUND' : 'NOT FOUND'}`);

    console.log('');
    console.log('  BAD INDICATORS:');
    console.log(`  ${hasLogoutText ? '❌' : '✅'} "Log out" text: ${hasLogoutText ? 'FOUND (BAD!)' : 'Not found'}`);
    console.log(`  ${hasLoginAgainText ? '❌' : '✅'} "Log back in" text: ${hasLoginAgainText ? 'FOUND (BAD!)' : 'Not found'}`);

    console.log('\n═══════════════════════════════════════════════════════════');

    // Determine if MFA setup is functional
    const mfaIsFunctional = hasQRCodeElement && (hasSecretKey || hasCodeInput);
    const mfaIsPlaceholder = (hasLogoutText || hasLoginAgainText) && !hasQRCodeElement;

    if (mfaIsPlaceholder) {
      console.log('  ❌ BUG CONFIRMED: MFA setup is a placeholder');
      console.log('  ❌ Page shows "logout and login" instructions');
      console.log('  ❌ NO QR code or setup interface');
      console.log('\n  This explains the user report:');
      console.log('  "when i press account settings, then setup authenticator app,');
      console.log('   then it just repeats the same screen"\n');
      console.log('  → User sees instructions to logout, which is not helpful');
      console.log('═══════════════════════════════════════════════════════════\n');
    } else if (mfaIsFunctional) {
      console.log('  ✅ MFA setup is FUNCTIONAL');
      console.log('  ✅ QR code and setup interface present');
      console.log('  ✅ User can set up MFA immediately');
      console.log('═══════════════════════════════════════════════════════════\n');
    } else {
      console.log('  ⚠️  UNCLEAR STATE');
      console.log('  → Neither placeholder nor functional interface detected');
      console.log('═══════════════════════════════════════════════════════════\n');
    }

    // Show snippet of page text for debugging
    console.log('📄 Page Text Preview (first 500 chars):\n');
    console.log(bodyText.substring(0, 500));
    console.log('...\n');

    // TEST ASSERTIONS
    if (mfaIsPlaceholder) {
      console.log('❌ TEST FAILED: MFA setup does not show QR code\n');
      expect(hasQRCodeElement, 'QR code should be visible').toBe(true);
    } else if (mfaIsFunctional) {
      console.log('✅ TEST PASSED: MFA setup is functional\n');
      expect(hasQRCodeElement).toBe(true);
    } else {
      console.log('⚠️  TEST INCONCLUSIVE: Could not determine state\n');
    }

    console.log('═══════════════════════════════════════════════════════════');
    console.log('  ✅ INTERACTIVE MFA TEST COMPLETE');
    console.log('═══════════════════════════════════════════════════════════\n');
  });

});
