const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

/**
 * Authentication Setup for Playwright Tests
 *
 * This script logs into the Cognito portal and saves the authenticated session.
 * Other tests can then reuse this session to test authenticated pages.
 *
 * Usage:
 *   TEST_USER=dmar@capsule.com TEST_PASSWORD=your_password node auth.setup.js
 */

async function globalSetup() {
  const testUser = process.env.TEST_USER || 'dmar@capsule.com';
  const testPassword = process.env.TEST_PASSWORD;

  if (!testPassword) {
    console.log('⚠️  No TEST_PASSWORD set - skipping authentication setup');
    console.log('   Authenticated tests will be skipped or fail');
    console.log('   Set with: TEST_USER=user@example.com TEST_PASSWORD=pass npm test');
    return;
  }

  console.log('🔐 Setting up authentication...');
  console.log(`   User: ${testUser}`);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    // Navigate to the portal (will redirect to Cognito login)
    console.log('   Navigating to portal...');
    await page.goto('https://portal.capsule-playground.com/', { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Wait a bit for redirect to complete
    await page.waitForTimeout(2000);

    // Check if we're on the login page
    const currentUrl = page.url();
    console.log(`   Current URL: ${currentUrl}`);

    if (!currentUrl.includes('auth') && !currentUrl.includes('login')) {
      console.log('   ⚠️  Already authenticated or not redirected to login');
      return;
    }

    // Wait for login form to be fully loaded
    console.log('   Waiting for login form...');
    await page.waitForLoadState('networkidle', { timeout: 10000 });

    // Find visible username and password inputs
    const usernameInput = page.locator('input[name="username"]:visible, input[id*="username"]:visible, input[placeholder*="email"]:visible').first();
    const passwordInput = page.locator('input[name="password"]:visible, input[id*="password"]:visible, input[type="password"]:visible').first();

    // Wait for inputs to be ready
    await usernameInput.waitFor({ state: 'visible', timeout: 10000 });
    await passwordInput.waitFor({ state: 'visible', timeout: 10000 });

    // Fill in credentials
    console.log('   Entering credentials...');
    await usernameInput.fill(testUser);
    await passwordInput.fill(testPassword);

    // Find and click submit button
    console.log('   Submitting login...');
    const submitButton = page.locator('input[type="submit"]:visible, button[type="submit"]:visible, button:has-text("Sign in"):visible').first();
    await submitButton.click();

    // Wait for redirect back to portal
    console.log('   Waiting for authentication...');
    await page.waitForURL('https://portal.capsule-playground.com/**', { timeout: 15000 });

    // Verify we're logged in by checking for authenticated content
    await page.waitForTimeout(2000);
    const finalUrl = page.url();

    if (finalUrl.includes('login') || finalUrl.includes('auth')) {
      throw new Error('Login failed - still on auth page');
    }

    // Save the authenticated state
    const authDir = path.join(__dirname, '.auth');
    if (!fs.existsSync(authDir)) {
      fs.mkdirSync(authDir, { recursive: true });
    }

    const storageState = path.join(authDir, 'user.json');
    await context.storageState({ path: storageState });

    console.log('   ✅ Authentication successful!');
    console.log(`   Session saved to: ${storageState}`);

  } catch (error) {
    console.error('   ❌ Authentication failed:', error.message);

    // Take screenshot for debugging
    const screenshotPath = path.join(__dirname, 'auth-failure.png');
    await page.screenshot({ path: screenshotPath, fullPage: true });
    console.log(`   Screenshot saved: ${screenshotPath}`);

    throw error;
  } finally {
    await browser.close();
  }
}

// Run if called directly
if (require.main === module) {
  globalSetup()
    .then(() => {
      console.log('✅ Setup complete');
      process.exit(0);
    })
    .catch((error) => {
      console.error('❌ Setup failed:', error);
      process.exit(1);
    });
}

module.exports = globalSetup;
