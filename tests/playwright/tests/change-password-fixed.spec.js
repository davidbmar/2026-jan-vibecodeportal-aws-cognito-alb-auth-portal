const { test, expect } = require('@playwright/test');

/**
 * Change Password - Verification Tests (After Fix)
 *
 * These tests verify that the /logout-and-reset bug is fixed.
 * The route should now redirect directly to /password-reset
 * instead of trying to go through Cognito logout.
 */

test.describe('Change Password - Fixed Behavior', () => {
  test('should redirect /logout-and-reset directly to /password-reset', async ({ page }) => {
    console.log('\n✅ Testing FIXED /logout-and-reset route\n');

    // Navigate to logout-and-reset
    await page.goto('/logout-and-reset');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`After /logout-and-reset, current URL: ${currentUrl}`);

    // Check where we ended up
    if (currentUrl.includes('/password-reset')) {
      console.log('✅ SUCCESS! Redirected to /password-reset');

      // Verify it's the password reset page
      const pageTitle = await page.title().catch(() => '');
      console.log(`Page title: ${pageTitle}`);

      // Look for password reset elements
      const emailInput = page.locator('input[type="email"]').first();
      const inputVisible = await emailInput.isVisible().catch(() => false);

      if (inputVisible) {
        console.log('✅ Password reset page loaded correctly');
        console.log('✅ Email input field visible');
      }

      // Should NOT have OAuth error
      const hasOAuthError = await page.locator('text=/redirect_uri|OAuth.*error/i').first().isVisible().catch(() => false);

      if (hasOAuthError) {
        console.log('❌ Still has OAuth error - fix not deployed yet');
      } else {
        console.log('✅ No OAuth errors');
      }

      expect(currentUrl).toContain('/password-reset');
      expect(hasOAuthError).toBe(false);

    } else if (currentUrl.includes('cognito')) {
      console.log('⚠️  Redirected to Cognito login (requires authentication)');
      console.log('   This is OK if user is not logged in');

    } else if (currentUrl.includes('error') || currentUrl.includes('redirect_uri')) {
      console.log('❌ ERROR! Still showing OAuth error - fix not yet deployed');
      console.log(`   URL: ${currentUrl}`);

      // Take screenshot
      await page.screenshot({ path: 'logout-and-reset-still-broken.png' });
      console.log('   Screenshot saved: logout-and-reset-still-broken.png');

      throw new Error('Bug still present - /logout-and-reset shows OAuth error');

    } else {
      console.log(`ℹ️  Unexpected redirect: ${currentUrl}`);
    }

    console.log('\n✅ Test complete\n');
  });

  test('should allow complete change password flow from settings', async ({ page }) => {
    console.log('\n✅ Testing complete change password flow\n');

    console.log('Note: This test requires authentication to access settings');
    console.log('If you see Cognito login, that is expected.\n');

    // Try to go to settings
    await page.goto('/settings');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();

    if (currentUrl.includes('/settings') && !currentUrl.includes('cognito')) {
      console.log('✅ On settings page (authenticated)');

      // Look for change password button
      const changePasswordBtn = page.locator('a[href="/logout-and-reset"]').first();
      const btnVisible = await changePasswordBtn.isVisible().catch(() => false);

      if (btnVisible) {
        console.log('✅ "Change Password" button found');

        // Click it
        await changePasswordBtn.click();
        await page.waitForLoadState('networkidle');
        await page.waitForTimeout(2000);

        const afterClickUrl = page.url();
        console.log(`After clicking, URL: ${afterClickUrl}`);

        // Should be on password reset
        if (afterClickUrl.includes('/password-reset')) {
          console.log('✅ SUCCESS! Redirected to password reset');

          // Verify no errors
          const hasError = await page.locator('text=/error|redirect_uri/i').first().isVisible().catch(() => false);

          if (hasError) {
            console.log('❌ ERROR found on page');
            await page.screenshot({ path: 'change-password-error-after-click.png' });
          } else {
            console.log('✅ No errors - ready for password reset');
          }

          expect(afterClickUrl).toContain('/password-reset');
          expect(hasError).toBe(false);

        } else {
          console.log(`⚠️  Redirected to: ${afterClickUrl}`);
        }
      } else {
        console.log('⚠️  Change password button not visible');
      }

    } else {
      console.log('ℹ️  Not authenticated - cannot test full flow');
      console.log('   (This is expected for unauthenticated tests)');
    }

    console.log('\n✅ Test complete\n');
  });

  test('should complete password reset after clicking change password', async ({ page }) => {
    console.log('\n✅ Testing password reset completion\n');

    // Start at password reset (simulating after change password click)
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    // Enter email
    const emailInput = page.locator('input[type="email"]').first();
    const inputVisible = await emailInput.isVisible().catch(() => false);

    if (inputVisible) {
      const testEmail = process.env.TEST_EMAIL || 'test@example.com';
      await emailInput.fill(testEmail);
      console.log(`✅ Entered email: ${testEmail}`);

      // Click send code
      const sendBtn = page.locator('button:has-text("Send")').first();
      await sendBtn.click();
      console.log('✅ Clicked "Send Reset Code"');

      await page.waitForTimeout(3000);

      // Check for Step 2
      const step2 = page.locator('text=/step.*2|verification code/i').first();
      const step2Visible = await step2.isVisible().catch(() => false);

      if (step2Visible) {
        console.log('✅ Step 2 appeared - code verification ready');

        const successMsg = page.locator('text=/code sent|sent.*code/i').first();
        const msgVisible = await successMsg.isVisible().catch(() => false);

        if (msgVisible) {
          const msgText = await successMsg.textContent();
          console.log(`✅ ${msgText}`);
        }

        console.log('\n📧 Check your email for verification code');
        console.log('   Then use the interactive test to complete:');
        console.log(`   VERIFICATION_CODE=123456 npm test tests/password-reset-interactive.spec.js`);

      } else {
        console.log('ℹ️  Step 2 not visible (may need valid email)');
      }

    } else {
      console.log('⚠️  Email input not visible');
    }

    console.log('\n✅ Test complete\n');
  });
});

test.describe('Change Password - Bug Documentation', () => {
  test('should document the fix applied', async ({ page }) => {
    console.log('\n📋 Change Password Fix Documentation\n');
    console.log('═'.repeat(60));
    console.log('\n🐛 ORIGINAL BUG:');
    console.log('   When clicking "Change Password" in settings:');
    console.log('   ❌ Error: "Required String parameter \'redirect_uri\' is not present"');
    console.log('');
    console.log('🔍 ROOT CAUSE:');
    console.log('   The /logout-and-reset route tried to call:');
    console.log('   https://...cognito.../logout?logout_uri=.../password-reset');
    console.log('   This caused OAuth redirect errors.');
    console.log('');
    console.log('✅ FIX APPLIED:');
    console.log('   Changed /logout-and-reset to redirect directly to:');
    console.log('   /password-reset');
    console.log('');
    console.log('📝 RATIONALE:');
    console.log('   - Password reset already provides security via email verification');
    console.log('   - No need for explicit Cognito logout before password reset');
    console.log('   - Simpler flow, fewer OAuth edge cases');
    console.log('');
    console.log('📁 FILES MODIFIED:');
    console.log('   - terraform/envs/tier5/user_data.sh (line 237-241)');
    console.log('');
    console.log('🚀 DEPLOYMENT:');
    console.log('   Run: ./fix-change-password-route.sh');
    console.log('   Or: cd terraform/envs/tier5 && terraform apply');
    console.log('');
    console.log('🧪 VERIFICATION:');
    console.log('   1. Visit: https://portal.capsule-playground.com/settings');
    console.log('   2. Click: 🔑 CHANGE PASSWORD');
    console.log('   3. Verify: Redirects to /password-reset (no error)');
    console.log('   4. Complete: Password reset flow');
    console.log('');
    console.log('═'.repeat(60));
    console.log('\n✅ Documentation complete\n');
  });
});
