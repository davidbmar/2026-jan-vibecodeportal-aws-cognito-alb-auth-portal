const { test } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const authFile = path.join(__dirname, '..', '.auth', 'user.json');

/**
 * Global Setup - Authenticates before running tests
 *
 * This runs once before all tests and creates an authenticated session
 * that can be reused by tests that need authentication.
 */
test('authenticate', async ({ page }) => {
  const testUser = process.env.TEST_USER || 'dmar@capsule.com';
  const testPassword = process.env.TEST_PASSWORD;

  if (!testPassword) {
    console.log('⚠️  No TEST_PASSWORD - skipping authentication');
    console.log('   Set with: TEST_USER=user@example.com TEST_PASSWORD=pass npm test');
    return;
  }

  console.log('🔐 Authenticating as:', testUser);

  // Navigate to portal
  await page.goto('https://portal.capsule-playground.com/');

  // Wait for redirect to login
  await page.waitForTimeout(2000);
  const currentUrl = page.url();

  if (!currentUrl.includes('auth') && !currentUrl.includes('login')) {
    console.log('⚠️  Not redirected to login - may already be authenticated');
    return;
  }

  // Wait for form
  await page.waitForLoadState('networkidle');

  // Fill credentials
  const usernameInput = page.locator('input[name="username"]:visible, input[id*="username"]:visible').first();
  const passwordInput = page.locator('input[name="password"]:visible, input[type="password"]:visible').first();

  await usernameInput.waitFor({ state: 'visible', timeout: 10000 });
  await usernameInput.fill(testUser);
  await passwordInput.fill(testPassword);

  // Submit
  const submitButton = page.locator('input[type="submit"]:visible, button[type="submit"]:visible').first();
  await submitButton.click();

  // Wait for redirect
  await page.waitForURL('https://portal.capsule-playground.com/**', { timeout: 15000 });

  // Save auth state
  await page.context().storageState({ path: authFile });

  console.log('✅ Authentication complete');
});
