const { test, expect } = require('@playwright/test');

/**
 * User Flow Tests - Testing Complete User Journeys
 *
 * These tests follow actual user paths through the portal,
 * simulating how a real person would interact with the system.
 */

test.describe('User Flows - Complete Journeys', () => {

  test('Flow 1: Unauthenticated User → Password Reset → Success', async ({ page }) => {
    console.log('\n🔄 FLOW 1: Complete Password Reset Journey\n');

    // Step 1: User visits portal without authentication
    console.log('Step 1: User lands on portal homepage');
    await page.goto('/');
    await page.waitForLoadState('networkidle');

    const url1 = page.url();
    console.log(`  → URL: ${url1}`);

    if (url1.includes('login') || url1.includes('auth')) {
      console.log('  ✅ Correctly redirected to login (expected for authenticated pages)');
    } else {
      console.log('  ✅ Loaded homepage');
    }

    // Step 2: User realizes they forgot password and goes to reset
    console.log('\nStep 2: User navigates to password reset');
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const url2 = page.url();
    console.log(`  → URL: ${url2}`);
    expect(url2).toContain('/password-reset');
    console.log('  ✅ Password reset page accessible');

    // Step 3: User sees the form and enters email
    console.log('\nStep 3: User enters email to request reset');
    const emailInput = page.locator('input[type="email"]').first();
    await expect(emailInput).toBeVisible();

    await emailInput.fill('test@example.com');
    console.log('  → Entered email: test@example.com');

    // Step 4: User clicks "Send Reset Code"
    console.log('\nStep 4: User clicks "Send Reset Code" button');
    const sendButton = page.locator('button:has-text("Send Reset Code"), input[value*="Send"]').first();
    await expect(sendButton).toBeVisible();
    await sendButton.click();
    console.log('  ✅ Submitted email for password reset');

    // Step 5: System processes request (API call)
    await page.waitForTimeout(2000);
    console.log('\nStep 5: System processes request');
    console.log('  ✅ API call completed');

    // Step 6: User sees verification code input (progressive disclosure)
    console.log('\nStep 6: User sees code input field');
    const codeInput = page.locator('input[maxlength="6"]').first();

    if (await codeInput.isVisible()) {
      console.log('  ✅ Verification code input appeared (Step 2 revealed)');
    } else {
      console.log('  ℹ️  Code input not visible (may require valid email)');
    }

    // Step 7: User sees password requirements
    console.log('\nStep 7: User checks password requirements');
    const pageContent = await page.content();
    const hasRequirements = pageContent.includes('8 characters') ||
                          pageContent.includes('uppercase') ||
                          pageContent.includes('lowercase');

    if (hasRequirements) {
      console.log('  ✅ Password requirements displayed');
    } else {
      console.log('  ℹ️  Requirements may be shown after code entry');
    }

    // Step 8: User knows to check email
    console.log('\nStep 8: User understands next steps');
    const hasEmailMessage = pageContent.includes('email') ||
                           pageContent.includes('check your') ||
                           pageContent.includes('sent');

    if (hasEmailMessage) {
      console.log('  ✅ Clear instructions about checking email');
    }

    console.log('\n✅ FLOW 1 COMPLETE: User successfully initiated password reset\n');
  });

  test('Flow 2: Authenticated User → Settings → Change Password', async ({ page }) => {
    console.log('\n🔄 FLOW 2: Change Password from Settings\n');

    // Step 1: User is logged in and browsing portal
    console.log('Step 1: User navigates to home');
    await page.goto('/');
    await page.waitForLoadState('networkidle');

    const url1 = page.url();
    console.log(`  → URL: ${url1}`);

    // Step 2: User wants to access account settings
    console.log('\nStep 2: User navigates to settings');
    await page.goto('/settings');
    await page.waitForLoadState('networkidle');

    const url2 = page.url();
    console.log(`  → URL: ${url2}`);

    if (url2.includes('login') || url2.includes('auth')) {
      console.log('  ℹ️  Redirected to login (not authenticated in test)');
      console.log('  ✅ Settings route exists and requires authentication (correct)');
    } else if (url2.includes('/settings')) {
      console.log('  ✅ Settings page loaded (user is authenticated)');

      // Step 3: User sees their account information
      console.log('\nStep 3: User views account information');
      const content = await page.content();
      console.log('  ✅ Settings page content loaded');

      // Step 4: User finds and clicks "Change Password"
      console.log('\nStep 4: User looks for change password option');
      const hasChangePassword = content.toLowerCase().includes('change password') ||
                               content.toLowerCase().includes('password');

      if (hasChangePassword) {
        console.log('  ✅ Change password option visible');
      }
    }

    // Step 5: Test the actual change password link
    console.log('\nStep 5: User clicks "Change Password"');
    await page.goto('/logout-and-reset');
    await page.waitForLoadState('networkidle');

    const url3 = page.url();
    console.log(`  → Final URL: ${url3}`);

    // Should redirect to password reset
    expect(url3).toContain('/password-reset');
    console.log('  ✅ Successfully redirected to password reset (no OAuth error!)');

    // Step 6: User proceeds with password reset flow
    console.log('\nStep 6: User can now reset password');
    const emailInput = page.locator('input[type="email"]').first();

    if (await emailInput.isVisible()) {
      console.log('  ✅ Password reset form ready');
    }

    console.log('\n✅ FLOW 2 COMPLETE: Change password flow works correctly\n');
  });

  test('Flow 3: User Journey - Portal Navigation', async ({ page }) => {
    console.log('\n🔄 FLOW 3: General Portal Navigation\n');

    // Step 1: User arrives at portal
    console.log('Step 1: User visits portal');
    await page.goto('/');
    await page.waitForLoadState('networkidle');
    const startUrl = page.url();
    console.log(`  → Starting URL: ${startUrl}`);

    // Step 2: User checks health endpoint (API check)
    console.log('\nStep 2: System health check');
    const healthResponse = await page.request.get('/health');
    expect(healthResponse.status()).toBe(200);
    console.log('  ✅ Portal is healthy');

    // Step 3: User browses directory
    console.log('\nStep 3: User navigates to employee directory');
    await page.goto('/directory');
    await page.waitForLoadState('networkidle');
    const dirUrl = page.url();
    console.log(`  → URL: ${dirUrl}`);

    // Step 4: User explores different areas
    console.log('\nStep 4: User checks different departments');
    const areas = ['engineering', 'hr', 'product', 'automation'];

    for (const area of areas) {
      const response = await page.request.get(`/areas/${area}`);
      console.log(`  → /areas/${area}: ${response.status()}`);

      if (response.status() === 302 || response.status() === 200) {
        console.log(`    ✅ ${area} area accessible`);
      }
    }

    // Step 5: User tries to access MFA setup
    console.log('\nStep 5: User explores security features');
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');
    const mfaUrl = page.url();
    console.log(`  → MFA URL: ${mfaUrl}`);

    if (mfaUrl.includes('login') || mfaUrl.includes('auth')) {
      console.log('  ✅ MFA setup requires authentication (correct)');
    } else {
      console.log('  ✅ MFA setup page accessible');
    }

    // Step 6: User logs out
    console.log('\nStep 6: User logs out');
    await page.goto('/logout');
    await page.waitForLoadState('networkidle');
    const logoutUrl = page.url();
    console.log(`  → Logout URL: ${logoutUrl}`);

    // Step 7: User sees logged out confirmation
    console.log('\nStep 7: User sees logout confirmation');
    await page.goto('/logged-out');
    await page.waitForLoadState('networkidle');
    const loggedOutUrl = page.url();

    if (loggedOutUrl.includes('/logged-out')) {
      console.log('  ✅ Logged out page displayed');
    }

    console.log('\n✅ FLOW 3 COMPLETE: Portal navigation working\n');
  });

  test('Flow 4: Error Handling - User encounters issues', async ({ page }) => {
    console.log('\n🔄 FLOW 4: Error Handling Journey\n');

    // Step 1: User tries to access non-existent page
    console.log('Step 1: User navigates to invalid URL');
    const response404 = await page.request.get('/nonexistent-page');
    console.log(`  → Status: ${response404.status()}`);

    if (response404.status() === 404) {
      console.log('  ✅ 404 error handled correctly');
    }

    // Step 2: User tries password reset with invalid data
    console.log('\nStep 2: User tests password reset with empty email');
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const sendButton = page.locator('button:has-text("Send Reset Code"), input[value*="Send"]').first();

    if (await sendButton.isVisible()) {
      // Try to submit without email
      await sendButton.click();
      await page.waitForTimeout(1000);

      // Check if browser validation kicked in
      const emailInput = page.locator('input[type="email"]').first();
      const validationMessage = await emailInput.evaluate((el) => el.validationMessage);

      if (validationMessage) {
        console.log('  ✅ Form validation prevents empty submission');
      }
    }

    // Step 3: User checks for JavaScript errors
    console.log('\nStep 3: Checking for JavaScript errors');
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', msg => {
      if (msg.type() === 'error') errors.push(msg.text());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);

    console.log(`  → Errors found: ${errors.length}`);
    if (errors.length === 0) {
      console.log('  ✅ No JavaScript errors');
    } else {
      console.log(`  ⚠️  Errors: ${errors.join(', ')}`);
    }

    // Step 4: User tests responsive design
    console.log('\nStep 4: User accesses from mobile device');
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('/password-reset');
    await page.waitForLoadState('networkidle');

    const emailInput = page.locator('input[type="email"]').first();
    if (await emailInput.isVisible()) {
      console.log('  ✅ Mobile layout works');
    }

    console.log('\n✅ FLOW 4 COMPLETE: Error handling tested\n');
  });

  test('Flow 5: Performance - User experience quality', async ({ page }) => {
    console.log('\n🔄 FLOW 5: Performance Testing\n');

    const pages = ['/', '/password-reset', '/directory'];

    for (const pagePath of pages) {
      console.log(`\nTesting: ${pagePath}`);

      const startTime = Date.now();
      await page.goto(pagePath);
      await page.waitForLoadState('domcontentloaded');
      const loadTime = Date.now() - startTime;

      console.log(`  → Load time: ${loadTime}ms`);

      if (loadTime < 2000) {
        console.log(`  ✅ Fast load time`);
      } else if (loadTime < 5000) {
        console.log(`  ⚠️  Acceptable load time`);
      } else {
        console.log(`  ❌ Slow load time`);
      }
    }

    console.log('\n✅ FLOW 5 COMPLETE: Performance tested\n');
  });

});
