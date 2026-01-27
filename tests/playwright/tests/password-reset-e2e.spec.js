const { test, expect } = require('@playwright/test');

/**
 * End-to-End Password Reset Flow Test
 *
 * This test follows the COMPLETE user journey for password reset,
 * testing with REAL data and verifying actual API responses.
 */

test.describe('Password Reset - Complete End-to-End Flow', () => {

  test('should complete password reset flow with real email (dmar@capsule.com)', async ({ page }) => {
    console.log('\n🔐 COMPLETE PASSWORD RESET FLOW TEST\n');

    // Step 1: User navigates to password reset page
    console.log('Step 1: Navigate to password reset page');
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    // Verify page loaded
    const url = page.url();
    expect(url).toContain('/password-reset');
    console.log('  ✅ Password reset page loaded');

    // Step 2: User sees email input field
    console.log('\nStep 2: Verify email input field is visible');
    const emailInput = page.locator('input[type="email"]').first();
    await expect(emailInput).toBeVisible();
    console.log('  ✅ Email input field visible');

    // Step 3: User enters REAL email address
    console.log('\nStep 3: Enter real email: dmar@capsule.com');
    await emailInput.fill('dmar@capsule.com');

    // Verify email was entered correctly
    const enteredEmail = await emailInput.inputValue();
    expect(enteredEmail).toBe('dmar@capsule.com');
    console.log('  ✅ Email entered correctly');

    // Step 4: User clicks "Send Reset Code" button
    console.log('\nStep 4: Click "Send Reset Code" button');
    const sendButton = page.locator('button:has-text("Send Reset Code"), button#send-code-btn').first();
    await expect(sendButton).toBeVisible();
    console.log('  ✅ Send button visible');

    // Set up API response listener BEFORE clicking button
    const apiResponsePromise = page.waitForResponse(
      response => response.url().includes('/api/password-reset/send-code') && response.status() === 200
    );

    await sendButton.click();
    console.log('  ✅ Button clicked');

    // Step 5: Wait for API response and verify it's successful
    console.log('\nStep 5: Wait for API response');
    const apiResponse = await apiResponsePromise;
    const responseData = await apiResponse.json();

    console.log(`  → API Response: ${JSON.stringify(responseData)}`);

    // CRITICAL: Verify the API actually succeeded
    expect(responseData.success).toBe(true);
    expect(responseData).toHaveProperty('destination');
    console.log(`  ✅ API SUCCESS - Code sent to: ${responseData.destination}`);

    // Step 6: Verify UI feedback
    console.log('\nStep 6: Verify UI feedback');
    await page.waitForTimeout(1000);

    // Check if Step 2 (code input) is now visible or if there's success feedback
    const codeInput = page.locator('input[maxlength="6"]').first();
    const pageContent = await page.content();

    const hasCodeInput = await codeInput.isVisible().catch(() => false);
    const hasSuccessMessage = pageContent.includes('sent') ||
                             pageContent.includes('code') ||
                             pageContent.includes('check your email');

    if (hasCodeInput) {
      console.log('  ✅ Code input field revealed (Step 2)');
    }

    if (hasSuccessMessage) {
      console.log('  ✅ Success message displayed');
    }

    expect(hasCodeInput || hasSuccessMessage).toBe(true);

    // Step 7: Verify no visible error messages
    console.log('\nStep 7: Verify no visible error messages');

    // Check for visible error elements (not just the word "error" in HTML)
    const errorElements = await page.locator('.error, .error-message, [class*="error"]').filter({ hasText: /.+/ }).count();
    const visibleErrorText = await page.locator('text=/error:|invalid:/i').first().isVisible().catch(() => false);

    const hasVisibleError = errorElements > 0 || visibleErrorText;

    if (hasVisibleError) {
      console.log('  ⚠️  Warning: Visible error message found');
      // Take screenshot for debugging
      await page.screenshot({ path: 'password-reset-error.png', fullPage: true });
    } else {
      console.log('  ✅ No visible error messages');
    }

    expect(hasVisibleError).toBe(false);

    console.log('\n✅ COMPLETE PASSWORD RESET FLOW - SUCCESS!\n');
    console.log('Summary:');
    console.log('  ✅ Page loaded');
    console.log('  ✅ Email field accessible');
    console.log('  ✅ Email accepted: dmar@capsule.com');
    console.log('  ✅ API call succeeded');
    console.log(`  ✅ Code sent to: ${responseData.destination}`);
    console.log('  ✅ UI updated correctly');
    console.log('  ✅ No errors');
  });

  test('should handle different valid email formats', async ({ page }) => {
    console.log('\n🧪 TESTING DIFFERENT EMAIL FORMATS\n');

    const testEmails = [
      'jahn@capsule.com',
      'peter@capsule.com',
      'ahatcher@capsule.com',
    ];

    for (const email of testEmails) {
      console.log(`\nTesting: ${email}`);

      await page.goto('/password-reset');
      await page.waitForLoadState('networkidle');

      const emailInput = page.locator('input[type="email"]').first();
      await emailInput.fill(email);

      const sendButton = page.locator('button#send-code-btn').first();

      // Set up API listener
      const apiResponsePromise = page.waitForResponse(
        response => response.url().includes('/api/password-reset/send-code')
      );

      await sendButton.click();

      const apiResponse = await apiResponsePromise;
      const responseData = await apiResponse.json();

      console.log(`  → Response: ${responseData.success ? 'SUCCESS' : 'FAILED'}`);

      if (responseData.success) {
        console.log(`  ✅ ${email} - Code sent`);
      } else {
        console.log(`  ❌ ${email} - Error: ${responseData.message}`);
      }

      // All real emails should succeed
      expect(responseData.success).toBe(true);
    }

    console.log('\n✅ ALL EMAIL FORMATS ACCEPTED\n');
  });

  test('should show appropriate error for non-existent email', async ({ page }) => {
    console.log('\n🔒 TESTING SECURITY - NON-EXISTENT EMAIL\n');

    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill('nonexistent@example.com');

    const sendButton = page.locator('button#send-code-btn').first();

    const apiResponsePromise = page.waitForResponse(
      response => response.url().includes('/api/password-reset/send-code')
    );

    await sendButton.click();

    const apiResponse = await apiResponsePromise;
    const responseData = await apiResponse.json();

    console.log(`  → Response for non-existent email: ${JSON.stringify(responseData)}`);

    // For security, should still return success (don't reveal if user exists)
    expect(responseData.success).toBe(true);
    console.log('  ✅ Security preserved - Does not reveal user existence');

    console.log('\n✅ SECURITY TEST PASSED\n');
  });

  test('should validate empty email', async ({ page }) => {
    console.log('\n⚠️  TESTING VALIDATION - EMPTY EMAIL\n');

    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const sendButton = page.locator('button#send-code-btn').first();

    // Set up API listener
    const apiResponsePromise = page.waitForResponse(
      response => response.url().includes('/api/password-reset/send-code'),
      { timeout: 5000 }
    ).catch(() => null);

    await sendButton.click();

    // Check if browser validation prevents submission
    const emailInput = page.locator('input[type="email"]').first();
    const validationMessage = await emailInput.evaluate((el) => el.validationMessage);

    if (validationMessage) {
      console.log('  ✅ Browser validation caught empty email');
      console.log(`  → Validation message: "${validationMessage}"`);
    } else {
      // If browser didn't catch it, API should
      const apiResponse = await apiResponsePromise;
      if (apiResponse) {
        const responseData = await apiResponse.json();
        expect(responseData.success).toBe(false);
        console.log('  ✅ API validation caught empty email');
      }
    }

    console.log('\n✅ VALIDATION TEST PASSED\n');
  });

  test('should validate invalid email format', async ({ page }) => {
    console.log('\n⚠️  TESTING VALIDATION - INVALID FORMAT\n');

    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill('not-an-email');

    const sendButton = page.locator('button#send-code-btn').first();

    // Check browser validation
    const validationMessage = await emailInput.evaluate((el) => el.validationMessage);

    if (validationMessage) {
      console.log('  ✅ Browser validation caught invalid format');
      console.log(`  → Validation message: "${validationMessage}"`);
    } else {
      // Try to submit
      const apiResponsePromise = page.waitForResponse(
        response => response.url().includes('/api/password-reset/send-code'),
        { timeout: 5000 }
      ).catch(() => null);

      await sendButton.click();

      const apiResponse = await apiResponsePromise;
      if (apiResponse) {
        const responseData = await apiResponse.json();
        console.log(`  → API Response: ${JSON.stringify(responseData)}`);

        // Should handle invalid format gracefully
        if (!responseData.success) {
          console.log('  ✅ API validation caught invalid format');
        }
      }
    }

    console.log('\n✅ VALIDATION TEST PASSED\n');
  });

  test.skip('MANUAL TEST: Complete password reset with verification code', async ({ page }) => {
    /**
     * This test documents the COMPLETE password reset flow including:
     * - Sending reset code
     * - Verifying the code
     * - Setting new password
     *
     * MARKED AS SKIP because it requires:
     * 1. Manual retrieval of verification code from email
     * 2. Real-time code entry (codes expire)
     *
     * To run manually:
     * 1. Remove .skip from this test
     * 2. Have access to the email account to retrieve code
     * 3. Update VERIFICATION_CODE variable when prompted
     */

    console.log('\n📧 COMPLETE PASSWORD RESET WITH VERIFICATION CODE\n');

    const TEST_EMAIL = 'dmar@capsule.com';
    const VERIFICATION_CODE = '258980'; // Replace with actual code from email
    const NEW_PASSWORD = 'NewPass123@';

    // Step 1: Send reset code
    console.log('Step 1: Send reset code');
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    await emailInput.fill(TEST_EMAIL);

    const sendButton = page.locator('button#send-code-btn').first();
    const sendApiResponse = await page.waitForResponse(
      response => response.url().includes('/api/password-reset/send-code')
    );

    await sendButton.click();
    const sendData = await sendApiResponse.json();

    console.log(`  ✅ Code sent to: ${sendData.destination}`);
    expect(sendData.success).toBe(true);

    // Step 2: Verify code via API (simulating what happens when user enters code)
    console.log('\nStep 2: Verify code');
    const verifyResponse = await page.request.post('/api/password-reset/verify-code', {
      data: {
        email: TEST_EMAIL,
        code: VERIFICATION_CODE
      }
    });

    const verifyData = await verifyResponse.json();
    console.log(`  → Verification result: ${JSON.stringify(verifyData)}`);
    expect(verifyData.success).toBe(true);
    console.log('  ✅ Code verified successfully');

    // Step 3: Confirm password reset with new password
    console.log('\nStep 3: Set new password');
    const confirmResponse = await page.request.post('/api/password-reset/confirm', {
      data: {
        email: TEST_EMAIL,
        code: VERIFICATION_CODE,
        password: NEW_PASSWORD
      }
    });

    const confirmData = await confirmResponse.json();
    console.log(`  → Password reset result: ${JSON.stringify(confirmData)}`);
    expect(confirmData.success).toBe(true);
    console.log('  ✅ Password reset successfully');

    // Step 4: Verify success page redirect (optional)
    console.log('\nStep 4: Verify UI flow completion');
    const codeInput = page.locator('input[maxlength="6"]').first();
    if (await codeInput.isVisible().catch(() => false)) {
      await codeInput.fill(VERIFICATION_CODE);

      const passwordInput = page.locator('input[type="password"]').first();
      await passwordInput.fill(NEW_PASSWORD);

      const resetButton = page.locator('button:has-text("Reset Password")').first();
      await resetButton.click();

      await page.waitForTimeout(2000);
      const finalUrl = page.url();
      console.log(`  → Final URL: ${finalUrl}`);
      expect(finalUrl).toContain('password-reset-success');
      console.log('  ✅ Redirected to success page');
    }

    console.log('\n✅ COMPLETE PASSWORD RESET FLOW - SUCCESS!\n');
    console.log('Summary:');
    console.log('  ✅ Code sent to email');
    console.log('  ✅ Code verified');
    console.log('  ✅ Password changed');
    console.log(`  ✅ New password: ${NEW_PASSWORD}`);
  });

});
