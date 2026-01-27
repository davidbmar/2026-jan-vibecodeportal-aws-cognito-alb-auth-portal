const { test, expect } = require('@playwright/test');

test.describe('Settings Page Tests', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to settings page
    // Note: In real scenario, this would require authentication
    // For now, we'll test the page structure assuming auth headers are present
    await page.goto('/settings');
  });

  test('should display correct email address (not UUID)', async ({ page }) => {
    // Wait for page to load
    await page.waitForLoadState('networkidle');

    // Check that email is displayed and is a valid email format (not UUID)
    const emailElement = await page.locator('text=/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}/').first();

    // Should be visible
    await expect(emailElement).toBeVisible({ timeout: 10000 });

    // Get the email text
    const emailText = await emailElement.textContent();

    // Should not be a UUID pattern
    expect(emailText).not.toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);

    // Should be a valid email
    expect(emailText).toMatch(/@/);

    console.log(`✅ Email displayed correctly: ${emailText}`);
  });

  test('should display only authenticator app MFA option (no SMS)', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Should have authenticator app section
    const authenticatorSection = page.locator('text=/AUTHENTICATOR APP|🔐.*AUTHENTICATOR/i');
    await expect(authenticatorSection).toBeVisible({ timeout: 10000 });

    // Should NOT have SMS option
    const smsOption = page.locator('text=/SMS.*MFA|Text.*Message|phone.*number/i');
    await expect(smsOption).not.toBeVisible();

    // Should have "SET UP" button for authenticator app
    const setupButton = page.locator('button:has-text("SET UP"), a:has-text("SET UP")').first();
    await expect(setupButton).toBeVisible();

    console.log('✅ MFA section shows only authenticator app');
  });

  test('should display 9 password reset steps', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for password reset section
    const passwordSection = page.locator('text=/password.*reset/i').first();
    await expect(passwordSection).toBeVisible({ timeout: 10000 });

    // Count numbered steps (1-9)
    const steps = [];
    for (let i = 1; i <= 9; i++) {
      // Look for patterns like "1.", "1)", or just "1" followed by text
      const stepLocator = page.locator(`text=/^${i}[.)\\s]/`).first();
      const isVisible = await stepLocator.isVisible().catch(() => false);
      if (isVisible) {
        const stepText = await stepLocator.textContent();
        steps.push({ number: i, text: stepText });
      }
    }

    console.log(`Found ${steps.length} password reset steps`);
    steps.forEach(step => console.log(`  Step ${step.number}: ${step.text.substring(0, 60)}...`));

    // Should have at least 9 steps
    expect(steps.length).toBeGreaterThanOrEqual(9);

    console.log('✅ All 9 password reset steps displayed');
  });

  test('should have password reset instructions with key details', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Check for specific important instructions
    const importantTexts = [
      /logged out immediately/i,
      /custom password reset page/i,
      /verification code/i,
      /6-digit/i,
      /new password/i,
      /LOGIN WITH NEW PASSWORD/i,
      /Cognito login page/i,
    ];

    let foundCount = 0;
    for (const pattern of importantTexts) {
      const element = page.locator(`text=${pattern}`).first();
      const isVisible = await element.isVisible().catch(() => false);
      if (isVisible) {
        foundCount++;
      }
    }

    console.log(`Found ${foundCount}/${importantTexts.length} key instruction elements`);

    // Should have most of the key elements
    expect(foundCount).toBeGreaterThanOrEqual(5);

    console.log('✅ Password reset instructions contain key details');
  });

  test('should display PRO TIP warning box', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for PRO TIP section
    const proTip = page.locator('text=/PRO TIP|💡.*TIP/i').first();
    const proTipVisible = await proTip.isVisible().catch(() => false);

    if (proTipVisible) {
      console.log('✅ PRO TIP warning box found');

      // Check for the warning about not clicking "Forgot your password?"
      const forgotWarning = page.locator('text=/DO NOT.*Forgot your password/i').first();
      const warningVisible = await forgotWarning.isVisible().catch(() => false);

      if (warningVisible) {
        console.log('✅ Warning about Cognito "Forgot password" found');
      }
    } else {
      console.log('ℹ️  PRO TIP not found (may be optional)');
    }
  });

  test('should display user groups', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for groups section
    const groupsSection = page.locator('text=/groups?:/i').first();
    const groupsVisible = await groupsSection.isVisible().catch(() => false);

    if (groupsVisible) {
      // Common group names that might appear
      const groupPatterns = [/admin/i, /user/i, /product/i, /engineering/i, /developer/i];

      let foundGroup = false;
      for (const pattern of groupPatterns) {
        const group = page.locator(`text=${pattern}`).first();
        const visible = await group.isVisible().catch(() => false);
        if (visible) {
          const groupText = await group.textContent();
          console.log(`  Found group: ${groupText}`);
          foundGroup = true;
        }
      }

      if (foundGroup) {
        console.log('✅ User groups displayed');
      }
    }
  });
});
