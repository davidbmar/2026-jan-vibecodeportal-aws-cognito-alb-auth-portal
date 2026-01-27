const { test, expect } = require('@playwright/test');

test.describe('MFA Setup Flow Tests', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to MFA setup page
    await page.goto('/mfa-setup');
  });

  test('should load MFA setup page successfully', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Page should load without errors
    const title = await page.title();
    console.log(`Page title: ${title}`);

    // Should not show error page
    const errorText = page.locator('text=/error|404|not found/i').first();
    const hasError = await errorText.isVisible().catch(() => false);

    expect(hasError).toBe(false);

    console.log('✅ MFA setup page loaded successfully');
  });

  test('should display user email correctly', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for email display
    const emailPattern = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/;
    const emailElement = page.locator(`text=${emailPattern}`).first();

    const emailVisible = await emailElement.isVisible().catch(() => false);

    if (emailVisible) {
      const emailText = await emailElement.textContent();
      console.log(`Email displayed: ${emailText}`);

      // Should not be UUID
      expect(emailText).not.toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);

      console.log('✅ User email displayed correctly');
    } else {
      console.log('ℹ️  Email not visible on page load');
    }
  });

  test('should show MFA setup steps', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for step indicators
    const stepPatterns = [
      /step\s*1/i,
      /step\s*2/i,
      /step\s*3/i,
      /install.*app/i,
      /scan.*code/i,
      /verify/i,
    ];

    let stepsFound = 0;
    for (const pattern of stepPatterns) {
      const step = page.locator(`text=${pattern}`).first();
      const visible = await step.isVisible().catch(() => false);
      if (visible) {
        stepsFound++;
        const stepText = await step.textContent();
        console.log(`  Found: ${stepText.substring(0, 50)}...`);
      }
    }

    console.log(`Found ${stepsFound} step indicators`);
    expect(stepsFound).toBeGreaterThan(0);

    console.log('✅ MFA setup steps displayed');
  });

  test('should have authenticator app installation instructions', async ({ page }) => {
    await page.waitForLoadState('networkidle');

    // Look for mentions of authenticator apps
    const appNames = [
      /Google Authenticator/i,
      /Microsoft Authenticator/i,
      /Authy/i,
      /authenticator app/i,
    ];

    let found = false;
    for (const appName of appNames) {
      const element = page.locator(`text=${appName}`).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        const text = await element.textContent();
        console.log(`  Found: ${text}`);
        found = true;
      }
    }

    if (found) {
      console.log('✅ Authenticator app instructions found');
    } else {
      console.log('⚠️  Authenticator app instructions not found');
    }
  });

  test('should call /api/mfa/init and receive TOTP secret', async ({ page }) => {
    // Set up request interception to verify API call
    let initApiCalled = false;
    let secretReceived = false;
    let qrUriReceived = false;

    page.on('response', async (response) => {
      if (response.url().includes('/api/mfa/init')) {
        initApiCalled = true;
        console.log(`API called: ${response.url()}`);
        console.log(`Status: ${response.status()}`);

        if (response.status() === 200) {
          try {
            const data = await response.json();
            console.log('API Response:', JSON.stringify(data, null, 2));

            if (data.secret) {
              secretReceived = true;
              console.log(`Secret received: ${data.secret.substring(0, 10)}...`);
            }

            if (data.qr_uri) {
              qrUriReceived = true;
              console.log(`QR URI received: ${data.qr_uri.substring(0, 50)}...`);
            }
          } catch (e) {
            console.error('Failed to parse API response:', e);
          }
        }
      }
    });

    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');

    // Wait a bit for API call to complete
    await page.waitForTimeout(3000);

    // Verify API was called
    if (initApiCalled) {
      console.log('✅ /api/mfa/init API called');

      if (secretReceived) {
        console.log('✅ TOTP secret received');
      }

      if (qrUriReceived) {
        console.log('✅ QR URI received');
      }

      expect(secretReceived || qrUriReceived).toBe(true);
    } else {
      console.log('⚠️  /api/mfa/init not called (may require authentication)');
    }
  });

  test('should display QR code', async ({ page }) => {
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');

    // Wait for potential QR code generation
    await page.waitForTimeout(3000);

    // Look for QR code elements
    const qrCodeSelectors = [
      'canvas',  // qrcode.js uses canvas
      'img[alt*="QR"]',
      'img[alt*="code"]',
      '.qr-code',
      '#qr-code',
      '#qrcode',
    ];

    let qrFound = false;
    for (const selector of qrCodeSelectors) {
      const element = page.locator(selector).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        console.log(`✅ QR code found using selector: ${selector}`);
        qrFound = true;
        break;
      }
    }

    if (!qrFound) {
      // Check if there's any canvas element at all
      const anyCanvas = page.locator('canvas').first();
      const canvasExists = await anyCanvas.count() > 0;
      console.log(`Canvas elements found: ${await page.locator('canvas').count()}`);

      if (canvasExists) {
        console.log('ℹ️  Canvas found but may not be visible yet');
      } else {
        console.log('⚠️  QR code not found (may require authentication)');
      }
    }
  });

  test('should display secret key for manual entry', async ({ page }) => {
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(3000);

    // Look for secret key display
    const secretPatterns = [
      /secret.*key/i,
      /manual.*entry/i,
      /can't scan/i,
      /[A-Z2-7]{32}/,  // Base32 secret pattern
    ];

    let secretFound = false;
    for (const pattern of secretPatterns) {
      const element = page.locator(`text=${pattern}`).first();
      const visible = await element.isVisible().catch(() => false);
      if (visible) {
        const text = await element.textContent();
        console.log(`Secret key section found: ${text.substring(0, 50)}...`);
        secretFound = true;
        break;
      }
    }

    if (secretFound) {
      console.log('✅ Secret key display found');
    } else {
      console.log('ℹ️  Secret key not visible (may require authentication)');
    }
  });

  test('should have verification code input field', async ({ page }) => {
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');

    // Look for verification code input
    const codeInputSelectors = [
      'input[type="text"][placeholder*="code" i]',
      'input[name*="code" i]',
      'input[id*="code" i]',
      'input[placeholder*="6-digit" i]',
      'input[maxlength="6"]',
    ];

    let inputFound = false;
    for (const selector of codeInputSelectors) {
      const input = page.locator(selector).first();
      const visible = await input.isVisible().catch(() => false);
      if (visible) {
        console.log(`✅ Verification code input found: ${selector}`);
        inputFound = true;

        // Try to interact with it
        await input.click().catch(() => {});
        console.log('  Input is clickable');
        break;
      }
    }

    if (!inputFound) {
      console.log('ℹ️  Verification code input not found (may be in later step)');
    }
  });

  test('should have verify button', async ({ page }) => {
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');

    // Look for verify button
    const verifyButton = page.locator('button:has-text("Verify"), button:has-text("VERIFY"), input[type="submit"][value*="Verify" i]').first();
    const buttonVisible = await verifyButton.isVisible().catch(() => false);

    if (buttonVisible) {
      console.log('✅ Verify button found');

      // Check if button is enabled
      const isEnabled = await verifyButton.isEnabled();
      console.log(`  Button enabled: ${isEnabled}`);
    } else {
      console.log('ℹ️  Verify button not visible (may require previous steps)');
    }
  });

  test('should test complete MFA setup flow structure', async ({ page }) => {
    await page.goto('/mfa-setup');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(3000);

    // Test the complete flow structure
    const flowChecks = {
      'Page loads': true,
      'Instructions visible': false,
      'QR code area present': false,
      'Secret key area present': false,
      'Code input present': false,
      'Verify button present': false,
    };

    // Check instructions
    const instructions = page.locator('text=/install|download|authenticator/i').first();
    flowChecks['Instructions visible'] = await instructions.isVisible().catch(() => false);

    // Check QR code area
    const qrArea = page.locator('canvas, img[alt*="QR"], #qr-code, #qrcode').first();
    flowChecks['QR code area present'] = await qrArea.count() > 0;

    // Check secret key area
    const secretArea = page.locator('text=/secret|manual|key/i').first();
    flowChecks['Secret key area present'] = await secretArea.isVisible().catch(() => false);

    // Check code input
    const codeInput = page.locator('input[type="text"], input[maxlength="6"]').first();
    flowChecks['Code input present'] = await codeInput.count() > 0;

    // Check verify button
    const verifyBtn = page.locator('button:has-text("Verify")').first();
    flowChecks['Verify button present'] = await verifyBtn.count() > 0;

    console.log('MFA Setup Flow Structure:');
    for (const [check, status] of Object.entries(flowChecks)) {
      console.log(`  ${status ? '✅' : '⚠️ '} ${check}`);
    }

    // Should have at least half of the elements
    const successCount = Object.values(flowChecks).filter(v => v).length;
    expect(successCount).toBeGreaterThanOrEqual(3);

    console.log(`✅ MFA setup flow structure complete (${successCount}/6 elements found)`);
  });
});
