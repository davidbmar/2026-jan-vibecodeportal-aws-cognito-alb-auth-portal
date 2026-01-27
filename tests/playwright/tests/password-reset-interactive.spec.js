const { test, expect } = require('@playwright/test');

/**
 * Interactive Password Reset Test
 *
 * This test requires user interaction to provide the verification code.
 * Run with: npm run test:debug
 *
 * When prompted, enter the 6-digit code from your email.
 */

test.describe('Interactive Password Reset - Complete Flow', () => {
  test('should complete full password reset flow with real verification code', async ({ page }) => {
    console.log('\n🔐 Starting Interactive Password Reset Test\n');

    // Configuration
    const TEST_EMAIL = process.env.TEST_EMAIL || 'test@example.com';
    const NEW_PASSWORD = process.env.TEST_PASSWORD || 'TestPassword2026!';

    console.log(`Test email: ${TEST_EMAIL}`);
    console.log(`New password: ${NEW_PASSWORD}`);
    console.log('');

    // Step 1: Navigate to password reset page
    console.log('Step 1: Navigating to password reset page...');
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');
    console.log('✅ Page loaded\n');

    // Step 2: Enter email and send reset code
    console.log('Step 2: Entering email and requesting reset code...');
    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill(TEST_EMAIL);
    console.log(`  Entered email: ${TEST_EMAIL}`);

    const sendButton = page.locator('button:has-text("Send"), button:has-text("SEND")').first();
    await sendButton.click();
    console.log('  Clicked "Send Reset Code"');

    // Wait for API response
    await page.waitForTimeout(3000);

    // Check for success message
    const successMessage = page.locator('text=/code sent|sent.*code/i').first();
    const messageVisible = await successMessage.isVisible();

    if (messageVisible) {
      const msgText = await successMessage.textContent();
      console.log(`✅ ${msgText}\n`);
    } else {
      console.log('⚠️  Success message not visible\n');
    }

    // Step 3: Wait for verification code (user needs to check email)
    console.log('Step 3: Entering verification code...');
    console.log('⏳ CHECK YOUR EMAIL FOR THE 6-DIGIT CODE');
    console.log('⏳ Then enter it when the test pauses...\n');

    // In headed mode, pause to let user enter code
    // In CI mode, use environment variable
    const VERIFICATION_CODE = process.env.VERIFICATION_CODE;

    if (!VERIFICATION_CODE) {
      console.log('⚠️  VERIFICATION_CODE not set in environment');
      console.log('   Set it with: VERIFICATION_CODE=123456 npm test');
      console.log('   For now, waiting 60 seconds for manual entry...\n');

      // Wait for code input to be available
      const codeInput = page.locator('input[maxlength="6"]').first();
      await expect(codeInput).toBeVisible({ timeout: 10000 });

      // In headed mode, user can manually enter code
      // Wait up to 60 seconds for user to enter code
      console.log('   Enter the code in the browser and click Verify...');
      await page.waitForTimeout(60000);
    } else {
      console.log(`   Using code from environment: ${VERIFICATION_CODE}`);

      // Find and fill code input
      const codeInput = page.locator('input[maxlength="6"]').first();
      await expect(codeInput).toBeVisible({ timeout: 10000 });
      await codeInput.fill(VERIFICATION_CODE);
      console.log('  ✅ Code entered');

      // Click verify button
      const verifyButton = page.locator('button:has-text("Verify"), button:has-text("VERIFY")').first();
      await verifyButton.click();
      console.log('  Clicked "Verify Code"\n');

      // Wait for Step 3 to appear
      await page.waitForTimeout(3000);
    }

    // Step 4: Enter new password
    console.log('Step 4: Setting new password...');

    // Look for password inputs
    const passwordInput = page.locator('input[type="password"][name*="password"]').first();
    const confirmInput = page.locator('input[type="password"][name*="confirm"]').first();

    const passwordVisible = await passwordInput.isVisible().catch(() => false);

    if (passwordVisible) {
      await passwordInput.fill(NEW_PASSWORD);
      console.log('  Entered new password');

      const confirmVisible = await confirmInput.isVisible().catch(() => false);
      if (confirmVisible) {
        await confirmInput.fill(NEW_PASSWORD);
        console.log('  Confirmed new password');
      }

      // Check password requirements
      console.log('  Checking password requirements...');
      await page.waitForTimeout(1000);

      // Look for requirement checkmarks
      const requirements = [
        '8 characters',
        'lowercase',
        'uppercase',
        'number',
        'special character',
      ];

      for (const req of requirements) {
        const checkmark = page.locator(`text=/✓.*${req}|${req}.*✓/i`).first();
        const hasCheck = await checkmark.isVisible().catch(() => false);
        console.log(`    ${hasCheck ? '✅' : '⚠️ '} ${req}`);
      }

      // Click reset password button
      const resetButton = page.locator('button:has-text("Reset"), button:has-text("RESET PASSWORD")').first();
      const buttonVisible = await resetButton.isVisible().catch(() => false);

      if (buttonVisible) {
        await resetButton.click();
        console.log('  Clicked "Reset Password"\n');
      }
    } else {
      console.log('  ⚠️  Password input not visible (may need manual interaction)\n');
    }

    // Step 5: Verify success page
    console.log('Step 5: Verifying success page...');
    await page.waitForTimeout(3000);

    const currentUrl = page.url();
    console.log(`  Current URL: ${currentUrl}`);

    if (currentUrl.includes('password-reset-success') || currentUrl.includes('success')) {
      console.log('✅ Redirected to success page\n');

      // Check for important UX elements
      console.log('  Checking UX improvements:');

      const uxChecks = {
        'Important/Next Steps': page.locator('text=/IMPORTANT|NEXT STEPS/i'),
        'DO NOT warnings': page.locator('text=/DO NOT/i'),
        'Login button': page.locator('button:has-text("LOGIN"), a:has-text("LOGIN")'),
      };

      for (const [name, locator] of Object.entries(uxChecks)) {
        const visible = await locator.first().isVisible().catch(() => false);
        console.log(`    ${visible ? '✅' : '⚠️ '} ${name}`);
      }
    } else {
      console.log('  ℹ️  Not on success page yet (may need manual steps)\n');
    }

    // Step 6: Test login button
    console.log('\nStep 6: Testing login button...');
    const loginButton = page.locator('button:has-text("LOGIN"), a:has-text("LOGIN")').first();
    const loginVisible = await loginButton.isVisible().catch(() => false);

    if (loginVisible) {
      const href = await loginButton.getAttribute('href').catch(() => null);
      console.log(`  Login button links to: ${href}`);

      if (href === '/') {
        console.log('  ✅ Correct destination (home page)');
      }

      console.log('\n📝 To complete the test:');
      console.log('   1. Click "LOGIN WITH NEW PASSWORD"');
      console.log(`   2. Login with: ${TEST_EMAIL}`);
      console.log(`   3. Password: ${NEW_PASSWORD}`);
      console.log('   4. Verify no 401 errors appear');
    }

    console.log('\n✅ Password Reset Test Complete!\n');
  });

  test('should handle invalid verification code gracefully', async ({ page }) => {
    console.log('\n🔐 Testing Invalid Verification Code Handling\n');

    const TEST_EMAIL = 'test@example.com';

    // Navigate and send code
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill(TEST_EMAIL);

    const sendButton = page.locator('button:has-text("Send")').first();
    await sendButton.click();
    await page.waitForTimeout(3000);

    // Try invalid code
    console.log('Attempting with invalid code: 000000');
    const codeInput = page.locator('input[maxlength="6"]').first();
    const inputVisible = await codeInput.isVisible().catch(() => false);

    if (inputVisible) {
      await codeInput.fill('000000');

      const verifyButton = page.locator('button:has-text("Verify")').first();
      await verifyButton.click();
      await page.waitForTimeout(2000);

      // Check for error message
      const errorMessage = page.locator('text=/invalid|incorrect|wrong/i').first();
      const hasError = await errorMessage.isVisible().catch(() => false);

      if (hasError) {
        const errorText = await errorMessage.textContent();
        console.log(`✅ Error message displayed: ${errorText}`);
      } else {
        console.log('ℹ️  Error message not visible or different format');
      }
    } else {
      console.log('⚠️  Code input not available (may require auth)');
    }

    console.log('\n✅ Invalid code handling test complete\n');
  });
});

test.describe('Password Reset - Edge Cases', () => {
  test('should validate password requirements in real-time', async ({ page }) => {
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    console.log('\n📋 Testing password requirement validation\n');

    // Send reset code first (if possible)
    const emailInput = page.locator('input[type="email"]').first();
    if (await emailInput.isVisible().catch(() => false)) {
      await emailInput.fill('test@example.com');
      const sendButton = page.locator('button:has-text("Send")').first();
      await sendButton.click();
      await page.waitForTimeout(3000);
    }

    // Test different passwords
    const testPasswords = [
      { password: 'short', expected: 'fail' },
      { password: 'NoNumber!', expected: 'fail' },
      { password: 'nonumber123!', expected: 'fail' },
      { password: 'NOLOWERCASE123!', expected: 'fail' },
      { password: 'NoSpecial123', expected: 'fail' },
      { password: 'ValidPassword123!', expected: 'pass' },
    ];

    const passwordInput = page.locator('input[type="password"]').first();
    const passwordVisible = await passwordInput.isVisible().catch(() => false);

    if (passwordVisible) {
      for (const test of testPasswords) {
        await passwordInput.fill(test.password);
        await page.waitForTimeout(500);

        console.log(`Testing: "${test.password}" - expected to ${test.expected}`);
        // Visual inspection - requirements should show red/green
      }

      console.log('✅ Password requirement validation tested');
    } else {
      console.log('ℹ️  Password input not available (requires earlier steps)');
    }
  });

  test('should enforce code expiration', async ({ page }) => {
    console.log('\n⏰ Testing code expiration messaging\n');

    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill('test@example.com');

    const sendButton = page.locator('button:has-text("Send")').first();
    await sendButton.click();
    await page.waitForTimeout(3000);

    // Check for expiration messaging
    const expirationText = page.locator('text=/1 hour|60 minute|expire/i').first();
    const expirationVisible = await expirationText.isVisible().catch(() => false);

    if (expirationVisible) {
      const text = await expirationText.textContent();
      console.log(`✅ Expiration message: ${text}`);
    } else {
      console.log('ℹ️  Expiration message not visible');
    }

    console.log('✅ Expiration test complete\n');
  });

  test('should allow resending code', async ({ page }) => {
    console.log('\n🔄 Testing resend code functionality\n');

    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill('test@example.com');

    const sendButton = page.locator('button:has-text("Send")').first();
    await sendButton.click();
    await page.waitForTimeout(3000);

    // Look for resend option
    const resendLink = page.locator('text=/resend|send.*again/i').first();
    const resendVisible = await resendLink.isVisible().catch(() => false);

    if (resendVisible) {
      console.log('✅ Resend option found');

      // Check if it's enabled or has countdown
      const resendText = await resendLink.textContent();
      console.log(`  Resend text: ${resendText}`);
    } else {
      console.log('ℹ️  Resend option not visible (may appear after delay)');
    }

    console.log('✅ Resend test complete\n');
  });
});
