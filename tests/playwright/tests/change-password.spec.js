const { test, expect } = require('@playwright/test');

/**
 * Change Password Flow Tests
 * Tests the "CHANGE PASSWORD" button in settings page
 *
 * Bug Report: Clicking "Change Password" shows error:
 * "Required String parameter 'redirect_uri' is not present"
 */

test.describe('Change Password Flow Tests', () => {
  test('should navigate to /logout-and-reset route', async ({ page }) => {
    console.log('\n🔍 Testing /logout-and-reset route directly\n');

    // Navigate directly to the logout-and-reset route
    await page.goto('/logout-and-reset');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`Current URL: ${currentUrl}`);

    // Check for error messages
    const errorPatterns = [
      /error/i,
      /redirect_uri/i,
      /parameter.*not present/i,
      /required string parameter/i,
    ];

    let foundError = false;
    for (const pattern of errorPatterns) {
      const errorElement = page.locator(`text=${pattern}`).first();
      const visible = await errorElement.isVisible().catch(() => false);
      if (visible) {
        const errorText = await errorElement.textContent();
        console.log(`❌ ERROR FOUND: ${errorText}`);
        foundError = true;
      }
    }

    // Take screenshot if error found
    if (foundError) {
      await page.screenshot({ path: 'change-password-error.png' });
      console.log('📸 Screenshot saved: change-password-error.png');
    }

    // Check where we ended up
    if (currentUrl.includes('password-reset')) {
      console.log('✅ Redirected to password reset page');
    } else if (currentUrl.includes('logout')) {
      console.log('⚠️  Still on logout page');
    } else if (currentUrl.includes('error')) {
      console.log('❌ Redirected to error page');
    } else {
      console.log(`ℹ️  Current page: ${currentUrl}`);
    }

    // The route should either:
    // 1. Redirect to /password-reset (correct)
    // 2. Show an error (bug to fix)

    console.log(`\nTest result: ${foundError ? 'BUG CONFIRMED' : 'Working or requires auth'}\n`);
  });

  test('should test logout-and-reset with referer header', async ({ page }) => {
    console.log('\n🔍 Testing with referer header (simulating button click)\n');

    // First go to settings (will redirect to login, but that's ok)
    await page.goto('/settings');
    await page.waitForTimeout(1000);

    // Now click the logout-and-reset link
    await page.goto('/logout-and-reset', {
      referer: 'https://portal.capsule-playground.com/settings'
    });
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`Current URL after logout-and-reset: ${currentUrl}`);

    // Check for errors
    const errorElement = page.locator('text=/error|redirect_uri/i').first();
    const hasError = await errorElement.isVisible().catch(() => false);

    if (hasError) {
      const errorText = await errorElement.textContent();
      console.log(`❌ ERROR: ${errorText}`);
    } else if (currentUrl.includes('password-reset')) {
      console.log('✅ Successfully redirected to password reset');
    } else {
      console.log(`ℹ️  Redirected to: ${currentUrl}`);
    }
  });

  test('should check if logout route exists', async ({ page }) => {
    console.log('\n🔍 Testing /logout route\n');

    // Test the logout route
    await page.goto('/logout');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`Logout redirects to: ${currentUrl}`);

    // Check for errors
    const errorElement = page.locator('text=/error|not found|404/i').first();
    const hasError = await errorElement.isVisible().catch(() => false);

    if (hasError) {
      console.log('❌ Logout route has error');
    } else {
      console.log('✅ Logout route exists');
    }
  });

  test('should verify settings page has change password button', async ({ page }) => {
    console.log('\n🔍 Testing settings page structure\n');

    await page.goto('/settings');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`Settings page URL: ${currentUrl}`);

    // If we're on settings page (authenticated)
    if (currentUrl.includes('/settings') && !currentUrl.includes('cognito')) {
      // Look for change password button
      const changePasswordButton = page.locator('a[href="/logout-and-reset"]').first();
      const buttonVisible = await changePasswordButton.isVisible().catch(() => false);

      if (buttonVisible) {
        console.log('✅ "Change Password" button found');
        const buttonText = await changePasswordButton.textContent();
        console.log(`   Button text: ${buttonText}`);

        // Try clicking it (if we're authenticated)
        console.log('\n   Attempting to click...');
        await changePasswordButton.click();
        await page.waitForTimeout(2000);

        const afterClickUrl = page.url();
        console.log(`   After click: ${afterClickUrl}`);

        // Check for error
        const error = page.locator('text=/error|redirect_uri/i').first();
        const hasError = await error.isVisible().catch(() => false);

        if (hasError) {
          const errorText = await error.textContent();
          console.log(`   ❌ ERROR AFTER CLICK: ${errorText}`);
          await page.screenshot({ path: 'change-password-button-error.png' });
        }
      } else {
        console.log('⚠️  Change Password button not found (page structure)');
      }
    } else {
      console.log('ℹ️  Not authenticated - can\'t test button click');
    }
  });

  test('should analyze the error message details', async ({ page }) => {
    console.log('\n🔍 Analyzing error details\n');

    // Go directly to the failing route
    await page.goto('/logout-and-reset');
    await page.waitForLoadState('networkidle');

    // Get all text on the page
    const bodyText = await page.locator('body').textContent();

    console.log('Page content analysis:');

    // Look for specific error patterns
    if (bodyText.includes('redirect_uri')) {
      console.log('❌ Found "redirect_uri" in error message');
    }

    if (bodyText.includes('Required String parameter')) {
      console.log('❌ Found "Required String parameter" - OAuth error');
    }

    if (bodyText.includes('not present')) {
      console.log('❌ Found "not present" - missing parameter');
    }

    // Look for stack traces or error details
    if (bodyText.includes('Exception') || bodyText.includes('Error')) {
      console.log('❌ Found Exception/Error keywords');
    }

    // Check what the current URL is
    const currentUrl = page.url();
    console.log(`\nCurrent URL: ${currentUrl}`);

    // If it's an OAuth URL, extract details
    if (currentUrl.includes('oauth')) {
      console.log('\n⚠️  Redirected to OAuth URL');

      const url = new URL(currentUrl);
      console.log(`   Host: ${url.hostname}`);
      console.log(`   Path: ${url.pathname}`);
      console.log('   Query params:');
      url.searchParams.forEach((value, key) => {
        console.log(`     ${key}: ${value.substring(0, 50)}${value.length > 50 ? '...' : ''}`);
      });
    }

    // Take screenshot for analysis
    await page.screenshot({ path: 'logout-and-reset-error-detail.png', fullPage: true });
    console.log('\n📸 Full page screenshot saved\n');
  });
});

test.describe('Change Password - Expected Flow', () => {
  test('should define the expected change password flow', async ({ page }) => {
    console.log('\n📋 Expected Change Password Flow:\n');
    console.log('1. User is on /settings (authenticated)');
    console.log('2. User clicks "🔑 CHANGE PASSWORD" button');
    console.log('3. System calls /logout-and-reset route');
    console.log('4. Route should:');
    console.log('   a. Log user out of current session');
    console.log('   b. Redirect to /password-reset');
    console.log('5. User enters email on password reset page');
    console.log('6. User receives verification code');
    console.log('7. User sets new password');
    console.log('8. User logs in with new password');
    console.log('\n❌ CURRENT BUG: Step 3-4 fails with OAuth redirect_uri error\n');
  });

  test('should document the fix needed', async ({ page }) => {
    console.log('\n🔧 Fix Needed:\n');
    console.log('The /logout-and-reset route needs to:');
    console.log('');
    console.log('Option 1: Simple redirect (no logout through OAuth)');
    console.log('  - Just redirect to /password-reset');
    console.log('  - Let password reset handle security');
    console.log('');
    console.log('Option 2: OAuth logout with proper redirect_uri');
    console.log('  - Call ALB logout: /oauth2/logout');
    console.log('  - Provide redirect_uri parameter');
    console.log('  - Redirect to /password-reset after logout');
    console.log('');
    console.log('Option 3: Combined approach');
    console.log('  - Clear local session');
    console.log('  - Redirect to /password-reset');
    console.log('  - Don\'t go through OAuth logout');
    console.log('');
  });
});
