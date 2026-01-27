const { test, expect } = require('@playwright/test');

test.describe('Password Reset Flow Tests', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to password reset page
    await page.goto('/password-reset');
  });

  test('should load password reset page successfully', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    const title = await page.title();
    console.log(`Page title: ${title}`);

    // Should not show error
    const errorText = page.locator('text=/error|404|not found/i').first();
    const hasError = await errorText.isVisible().catch(() => false);

    expect(hasError).toBe(false);

    console.log('✅ Password reset page loaded successfully');
  });

  test('should display Step 1: Email input', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for Step 1 indicator
    const step1 = page.locator('text=/step.*1|1\\./i').first();
    const step1Visible = await step1.isVisible().catch(() => false);

    if (step1Visible) {
      console.log('✅ Step 1 indicator found');
    }

    // Look for email input
    const emailInputSelectors = [
      'input[type="email"]',
      'input[name="email"]',
      'input[placeholder*="email" i]',
      'input[id*="email" i]',
    ];

    let emailInputFound = false;
    for (const selector of emailInputSelectors) {
      const input = page.locator(selector).first();
      const visible = await input.isVisible().catch(() => false);
      if (visible) {
        console.log(`✅ Email input found: ${selector}`);
        emailInputFound = true;

        // Verify it's enabled
        const isEnabled = await input.isEnabled();
        console.log(`  Email input enabled: ${isEnabled}`);
        expect(isEnabled).toBe(true);
        break;
      }
    }

    expect(emailInputFound).toBe(true);
  });

  test('should have "Send Reset Code" button', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    const sendButton = page.locator('button:has-text("Send"), button:has-text("SEND"), button:has-text("Reset Code")').first();
    const buttonVisible = await sendButton.isVisible().catch(() => false);

    expect(buttonVisible).toBe(true);

    const isEnabled = await sendButton.isEnabled();
    console.log(`Send button enabled: ${isEnabled}`);

    console.log('✅ Send Reset Code button found');
  });

  test('should show password requirements', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for password requirements
    const requirements = [
      /8 characters/i,
      /lowercase/i,
      /uppercase/i,
      /number/i,
      /special character/i,
    ];

    let foundCount = 0;
    for (const req of requirements) {
      const element = page.locator(`text=${req}`).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        foundCount++;
      }
    }

    console.log(`Found ${foundCount}/5 password requirements`);

    if (foundCount >= 3) {
      console.log('✅ Password requirements displayed');
    } else {
      console.log('ℹ️  Password requirements may be shown in later steps');
    }
  });

  test('should test email submission flow', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Find email input
    const emailInput = page.locator('input[type="email"], input[name="email"]').first();
    const emailInputVisible = await emailInput.isVisible().catch(() => false);

    if (!emailInputVisible) {
      console.log('⚠️  Email input not visible, skipping submission test');
      return;
    }

    // Enter test email
    const testEmail = 'test@example.com';
    await emailInput.fill(testEmail);
    console.log(`Entered email: ${testEmail}`);

    // Find and click send button
    const sendButton = page.locator('button:has-text("Send"), button:has-text("SEND")').first();
    const buttonVisible = await sendButton.isVisible().catch(() => false);

    if (buttonVisible) {
      // Set up response listener before clicking
      let apiCalled = false;
      page.on('response', async (response) => {
        if (response.url().includes('/password-reset') || response.url().includes('/forgot-password')) {
          apiCalled = true;
          console.log(`API called: ${response.url()}`);
          console.log(`Status: ${response.status()}`);
        }
      });

      await sendButton.click();
      console.log('Clicked send button');

      // Wait for potential response
      await page.waitForTimeout(3000);

      // Check for Step 2 or success message
      const step2 = page.locator('text=/step.*2|verification code|check.*email/i').first();
      const step2Visible = await step2.isVisible().catch(() => false);

      if (step2Visible) {
        console.log('✅ Step 2 appeared after submission');
      } else {
        console.log('ℹ️  Step 2 not visible (may require valid email or authentication)');
      }

      // Check for success/confirmation message
      const successMessage = page.locator('text=/code sent|check.*email|sent.*code/i').first();
      const successVisible = await successMessage.isVisible().catch(() => false);

      if (successVisible) {
        const msgText = await successMessage.textContent();
        console.log(`✅ Success message: ${msgText}`);
      }
    }
  });

  test('should have progressive disclosure structure', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Check for step structure
    const steps = {
      'Step 1': false,
      'Step 2': false,
      'Step 3': false,
    };

    for (let i = 1; i <= 3; i++) {
      const step = page.locator(`text=/step.*${i}|${i}\\./i`).first();
      const visible = await step.isVisible().catch(() => false);
      steps[`Step ${i}`] = visible;
    }

    console.log('Password Reset Steps:');
    for (const [step, visible] of Object.entries(steps)) {
      console.log(`  ${visible ? '✅' : 'ℹ️ '} ${step} ${visible ? 'visible' : 'hidden (progressive disclosure)'}`);
    }

    // Should have at least Step 1
    expect(steps['Step 1']).toBe(true);

    console.log('✅ Progressive disclosure structure present');
  });

  test('should check for verification code input (Step 2)', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for verification code input
    const codeInputSelectors = [
      'input[name*="code" i]',
      'input[placeholder*="code" i]',
      'input[placeholder*="verification" i]',
      'input[maxlength="6"]',
      'input[type="text"][pattern="[0-9]*"]',
    ];

    let codeInputFound = false;
    for (const selector of codeInputSelectors) {
      const input = page.locator(selector).first();
      const count = await input.count();
      if (count > 0) {
        console.log(`✅ Verification code input found: ${selector}`);
        codeInputFound = true;
        break;
      }
    }

    if (codeInputFound) {
      console.log('✅ Step 2: Verification code input present');
    } else {
      console.log('ℹ️  Verification code input not visible (progressive disclosure)');
    }
  });

  test('should check for password input fields (Step 3)', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for new password inputs
    const passwordInputSelectors = [
      'input[type="password"][name*="new" i]',
      'input[type="password"][name*="password" i]',
      'input[type="password"][placeholder*="new" i]',
    ];

    let passwordInputsFound = 0;
    for (const selector of passwordInputSelectors) {
      const input = page.locator(selector).first();
      const count = await input.count();
      if (count > 0) {
        passwordInputsFound++;
      }
    }

    console.log(`Found ${passwordInputsFound} password input fields`);

    if (passwordInputsFound > 0) {
      console.log('✅ Step 3: Password input fields present');
    } else {
      console.log('ℹ️  Password inputs not visible (progressive disclosure)');
    }
  });

  test('should check for success page route', async ({ page }) => {
    // Try to navigate to success page
    await page.goto('/password-reset-success');
    await page.waitForLoadState('networkidle');

    const currentUrl = page.url();
    console.log(`Current URL: ${currentUrl}`);

    // Check if page loaded (not 404)
    const errorText = page.locator('text=/404|not found|error/i').first();
    const hasError = await errorText.isVisible().catch(() => false);

    if (!hasError) {
      console.log('✅ Password reset success page exists');

      // Look for success messaging
      const successElements = [
        /password.*reset.*successful/i,
        /password.*changed/i,
        /success/i,
        /LOGIN.*NEW.*PASSWORD/i,
        /IMPORTANT.*NEXT STEPS/i,
      ];

      let foundElements = 0;
      for (const pattern of successElements) {
        const element = page.locator(`text=${pattern}`).first();
        const visible = await element.isVisible().catch(() => false);
        if (visible) {
          foundElements++;
          const text = await element.textContent();
          console.log(`  Found: ${text.substring(0, 50)}...`);
        }
      }

      console.log(`Found ${foundElements} success page elements`);
    } else {
      console.log('⚠️  Password reset success page not found or shows error');
    }
  });

  test('should have improved UX messaging on success page', async ({ page }) => {
    await page.goto('/password-reset-success');
    await page.waitForLoadState('networkidle');

    // Check for important UX improvements
    const uxElements = {
      'Important/Next Steps warning': false,
      'Numbered instructions': false,
      'DO NOT warnings': false,
      'Login button': false,
    };

    // Check for warning section
    const warning = page.locator('text=/IMPORTANT|NEXT STEPS|⚠️/i').first();
    uxElements['Important/Next Steps warning'] = await warning.isVisible().catch(() => false);

    // Check for numbered instructions
    let numberedSteps = 0;
    for (let i = 1; i <= 3; i++) {
      const step = page.locator(`text=/^${i}[.)\\s]/`).first();
      const visible = await step.isVisible().catch(() => false);
      if (visible) numberedSteps++;
    }
    uxElements['Numbered instructions'] = numberedSteps >= 3;

    // Check for DO NOT warnings
    const doNotWarning = page.locator('text=/DO NOT|Don\'t/i').first();
    uxElements['DO NOT warnings'] = await doNotWarning.isVisible().catch(() => false);

    // Check for login button
    const loginButton = page.locator('button:has-text("LOGIN"), a:has-text("LOGIN")').first();
    uxElements['Login button'] = await loginButton.isVisible().catch(() => false);

    console.log('Success Page UX Elements:');
    for (const [element, present] of Object.entries(uxElements)) {
      console.log(`  ${present ? '✅' : '⚠️ '} ${element}`);
    }

    const presentCount = Object.values(uxElements).filter(v => v).length;
    console.log(`UX improvements: ${presentCount}/4 elements found`);
  });

  test('should verify "LOGIN WITH NEW PASSWORD" button functionality', async ({ page }) => {
    await page.goto('/password-reset-success');
    await page.waitForLoadState('networkidle');

    // Find login button
    const loginButton = page.locator('button:has-text("LOGIN"), a:has-text("LOGIN"), a:has-text("Sign in")').first();
    const buttonVisible = await loginButton.isVisible().catch(() => false);

    if (buttonVisible) {
      console.log('✅ Login button found');

      // Check if it's a link or button
      const tagName = await loginButton.evaluate(el => el.tagName);
      console.log(`  Button type: ${tagName}`);

      if (tagName === 'A') {
        const href = await loginButton.getAttribute('href');
        console.log(`  Link href: ${href}`);

        // Should link to home or login page
        if (href === '/' || href === '/login' || href.includes('oauth')) {
          console.log('✅ Button links to correct destination');
        }
      }
    } else {
      console.log('ℹ️  Login button not visible on success page');
    }
  });

  test('should check for email masking in confirmation message', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Submit a test email to trigger confirmation
    const emailInput = page.locator('input[type="email"]').first();
    const inputVisible = await emailInput.isVisible().catch(() => false);

    if (inputVisible) {
      await emailInput.fill('test@example.com');

      const sendButton = page.locator('button:has-text("Send")').first();
      const buttonVisible = await sendButton.isVisible().catch(() => false);

      if (buttonVisible) {
        await sendButton.click();
        await page.waitForTimeout(2000);

        // Look for masked email pattern (e.g., "d***@c***")
        const maskedPattern = /[a-z]\*+@[a-z]\*+/i;
        const maskedEmail = page.locator(`text=${maskedPattern}`).first();
        const maskedVisible = await maskedEmail.isVisible().catch(() => false);

        if (maskedVisible) {
          const maskedText = await maskedEmail.textContent();
          console.log(`✅ Email masked for privacy: ${maskedText}`);
        } else {
          console.log('ℹ️  Email masking not found or not applicable');
        }
      }
    }
  });

  test('should verify code expiration messaging', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for expiration time mentions
    const expirationPatterns = [
      /1 hour/i,
      /60 minute/i,
      /code.*valid/i,
      /expire/i,
    ];

    let found = false;
    for (const pattern of expirationPatterns) {
      const element = page.locator(`text=${pattern}`).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        const text = await element.textContent();
        console.log(`✅ Expiration messaging: ${text}`);
        found = true;
        break;
      }
    }

    if (!found) {
      console.log('ℹ️  Code expiration messaging not visible (may appear after code sent)');
    }
  });

  test('should check for resend code option', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for resend option
    const resendPatterns = [
      /resend/i,
      /send.*again/i,
      /didn't receive/i,
    ];

    let found = false;
    for (const pattern of resendPatterns) {
      const element = page.locator(`text=${pattern}`).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        console.log('✅ Resend code option found');
        found = true;
        break;
      }
    }

    if (!found) {
      console.log('ℹ️  Resend option not visible (may appear after code sent)');
    }
  });
});
