const { test, expect } = require('@playwright/test');

/**
 * MFA Setup - Complete User Flow Test
 *
 * This test follows the EXACT user journey reported by the user:
 * 1. Navigate to Settings
 * 2. Click "SET UP AUTHENTICATOR APP" button
 * 3. Should see MFA setup page with QR code (NOT just instructions to logout)
 *
 * This tests the ACTUAL clickable flow, not just individual page loads.
 */

test.describe('MFA Setup - Complete User Flow', () => {

  test('USER FLOW: Settings → Click MFA Setup → See QR Code', async ({ page }) => {
    console.log('\n🔐 COMPLETE MFA SETUP USER FLOW TEST\n');

    // Step 1: User navigates to settings
    console.log('Step 1: Navigate to /settings');
    await page.goto('/settings');
    await page.waitForLoadState('networkidle');

    const url1 = page.url();
    console.log(`  → Current URL: ${url1}`);

    // Check if we're redirected to login (expected without auth)
    if (url1.includes('login') || url1.includes('auth')) {
      console.log('  ℹ️  Redirected to login (requires authentication)');
      console.log('  ⚠️  Cannot test full flow without authentication');
      console.log('  ✅ Test skipped - authentication required');
      test.skip();
      return;
    }

    console.log('  ✅ Settings page loaded');

    // Step 2: User sees and clicks "SET UP AUTHENTICATOR APP" button
    console.log('\nStep 2: Look for "SET UP AUTHENTICATOR APP" button');

    const mfaButton = page.locator('a:has-text("SET UP AUTHENTICATOR APP"), button:has-text("SET UP AUTHENTICATOR APP")').first();
    const buttonVisible = await mfaButton.isVisible().catch(() => false);

    if (!buttonVisible) {
      console.log('  ❌ BUTTON NOT FOUND!');
      console.log('  This is a critical bug - button should be on settings page');

      // Take screenshot for debugging
      await page.screenshot({ path: 'mfa-button-missing.png', fullPage: true });

      expect(buttonVisible).toBe(true);
      return;
    }

    console.log('  ✅ Found button');

    // Get button href to verify it points to /mfa-setup
    const buttonHref = await mfaButton.getAttribute('href').catch(() => null);
    console.log(`  → Button href: ${buttonHref}`);

    if (buttonHref && !buttonHref.includes('mfa-setup')) {
      console.log(`  ⚠️  Warning: Button href doesn't point to mfa-setup: ${buttonHref}`);
    }

    // Step 3: User clicks the button
    console.log('\nStep 3: Click "SET UP AUTHENTICATOR APP" button');
    await mfaButton.click();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000); // Wait for any dynamic content

    const url2 = page.url();
    console.log(`  → Current URL: ${url2}`);

    // Verify we reached /mfa-setup
    if (!url2.includes('mfa-setup')) {
      console.log(`  ❌ DID NOT NAVIGATE TO MFA SETUP PAGE!`);
      console.log(`  → Expected URL to contain: mfa-setup`);
      console.log(`  → Actual URL: ${url2}`);
      expect(url2).toContain('mfa-setup');
      return;
    }

    console.log('  ✅ Navigated to /mfa-setup page');

    // Step 4: Check what user actually sees
    console.log('\nStep 4: Verify what user sees on MFA setup page');

    const pageContent = await page.content();

    // Check for BAD indicators (instructions to logout)
    const hasLogoutInstructions = pageContent.toLowerCase().includes('log out') ||
                                   pageContent.toLowerCase().includes('logout') ||
                                   pageContent.toLowerCase().includes('log back in');

    // Check for GOOD indicators (actual MFA setup)
    const hasQRCode = await page.locator('canvas, img[alt*="QR"], #qr-code, #qrcode').count() > 0;
    const hasSecretKey = /[A-Z2-7]{32}/.test(pageContent); // Base32 secret pattern
    const hasCodeInput = await page.locator('input[type="text"], input[maxlength="6"]').count() > 0;
    const hasVerifyButton = await page.locator('button:has-text("Verify"), button:has-text("VERIFY")').count() > 0;

    console.log('\n📊 What user sees:');
    console.log(`  ${hasLogoutInstructions ? '❌' : '✅'} Instructions to logout: ${hasLogoutInstructions}`);
    console.log(`  ${hasQRCode ? '✅' : '❌'} QR Code visible: ${hasQRCode}`);
    console.log(`  ${hasSecretKey ? '✅' : '❌'} Secret key visible: ${hasSecretKey}`);
    console.log(`  ${hasCodeInput ? '✅' : '❌'} Code input field: ${hasCodeInput}`);
    console.log(`  ${hasVerifyButton ? '✅' : '❌'} Verify button: ${hasVerifyButton}`);

    // Step 5: Check if API was called
    console.log('\nStep 5: Check if /api/mfa/init was called');

    let apiCalled = false;
    let apiResponse = null;

    page.on('response', async (response) => {
      if (response.url().includes('/api/mfa/init')) {
        apiCalled = true;
        console.log(`  ✅ API called: ${response.url()}`);
        console.log(`  → Status: ${response.status()}`);

        if (response.status() === 200) {
          try {
            apiResponse = await response.json();
            console.log('  → Response:', JSON.stringify(apiResponse, null, 2));
          } catch (e) {
            console.log('  ⚠️  Could not parse API response');
          }
        }
      }
    });

    // Reload page to trigger API call check
    await page.reload();
    await page.waitForTimeout(3000);

    if (!apiCalled) {
      console.log('  ⚠️  /api/mfa/init API not called');
    }

    // Take screenshot for documentation
    await page.screenshot({ path: 'mfa-setup-actual-view.png', fullPage: true });

    // Step 6: Report findings
    console.log('\n📋 ANALYSIS:');

    if (hasLogoutInstructions && !hasQRCode && !hasCodeInput) {
      console.log('  ❌ BUG CONFIRMED: Page only shows "logout and login" instructions');
      console.log('  ❌ Expected: QR code, secret key, and code input for immediate setup');
      console.log('  ❌ Actual: Instructions to logout and go through Cognito flow');
      console.log('\n  This explains user\'s report: "it just repeats the same screen"');
      console.log('  User clicks button, sees instructions to logout, which is not helpful.');
    } else if (hasQRCode || hasCodeInput) {
      console.log('  ✅ MFA setup page shows actual setup interface');
      console.log('  ✅ User can set up MFA immediately');
    } else {
      console.log('  ⚠️  Unclear state - neither logout instructions nor setup interface');
    }

    // Test assertion: Should NOT have logout instructions
    if (hasLogoutInstructions && !hasQRCode) {
      console.log('\n❌ TEST FAILED: MFA setup is not functional');
      console.log('   User cannot set up MFA from this page');
      console.log('   Page should show QR code and setup interface');

      expect(hasLogoutInstructions).toBe(false);
    }

    // Test assertion: SHOULD have MFA setup interface
    const hasMfaSetupInterface = hasQRCode || hasCodeInput || hasVerifyButton;
    console.log(`\n${hasMfaSetupInterface ? '✅' : '❌'} MFA setup interface present: ${hasMfaSetupInterface}`);

    expect(hasMfaSetupInterface).toBe(true);

    console.log('\n✅ COMPLETE MFA SETUP USER FLOW - TEST COMPLETE\n');
  });

  test('VERIFY: /mfa-setup page structure when accessed directly', async ({ page }) => {
    console.log('\n🔍 DIRECT ACCESS TO /mfa-setup PAGE\n');

    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);

    const url = page.url();
    console.log(`Current URL: ${url}`);

    if (url.includes('login') || url.includes('auth')) {
      console.log('ℹ️  Redirected to login (requires authentication)');
      console.log('✅ Test skipped - authentication required');
      test.skip();
      return;
    }

    console.log('\nPage Content Analysis:');

    // Check what's actually on the page
    const pageText = await page.locator('body').textContent();

    const indicators = {
      'Has "logout" instructions': /log out|logout/i.test(pageText),
      'Has "log back in" instructions': /log back in|log in again/i.test(pageText),
      'Has "QR code" mention': /qr code|scan.*code/i.test(pageText),
      'Has QR code element': await page.locator('canvas, img[alt*="QR"], #qr-code').count() > 0,
      'Has authenticator app mention': /google authenticator|microsoft authenticator|authy/i.test(pageText),
      'Has code input field': await page.locator('input[maxlength="6"]').count() > 0,
      'Has verify button': await page.locator('button:has-text("Verify")').count() > 0,
      'Has MFA mentioned': /mfa|multi-factor/i.test(pageText),
    };

    for (const [check, result] of Object.entries(indicators)) {
      console.log(`  ${result ? '✅' : '❌'} ${check}: ${result}`);
    }

    // Take screenshot
    await page.screenshot({ path: 'mfa-setup-direct-access.png', fullPage: true });

    console.log('\n✅ Direct access verification complete');
  });

});
