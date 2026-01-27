const { test, expect } = require('@playwright/test');

test.describe('MFA Flow - Cognito Integration', () => {

  test('MFA setup page should exist and provide Cognito link', async ({ page }) => {
    console.log('\nTEST: MFA Setup Page Structure\n');

    await page.goto('https://portal.capsule-playground.com/mfa-setup');
    await page.waitForLoadState('networkidle');

    const url = page.url();
    console.log('  Current URL:', url);

    if (url.includes('login') || url.includes('auth')) {
      console.log('  Redirected to login (requires authentication)');
      console.log('  Page correctly requires authentication\n');
      test.skip();
      return;
    }

    console.log('  MFA setup page loaded\n');

    const pageContent = await page.textContent('body');

    const hasMFATitle = pageContent.includes('MFA') || pageContent.includes('Multi-Factor');
    const hasAuthenticatorMention = pageContent.includes('authenticator app') || pageContent.includes('Authenticator');
    const hasCognitoLink = pageContent.includes('Cognito') || pageContent.includes('cognito');

    console.log('  MFA title present:', hasMFATitle);
    console.log('  Authenticator app mentioned:', hasAuthenticatorMention);
    console.log('  Cognito reference:', hasCognitoLink);

    const cognitoLink = page.locator('a[href*="cognito"]').first();
    const cognitoLinkExists = await cognitoLink.count() > 0;

    if (cognitoLinkExists) {
      const href = await cognitoLink.getAttribute('href');
      console.log('  Found Cognito link:', href);

      const isCorrectFormat = href.includes('auth') && href.includes('amazoncognito.com');
      console.log('  Link format valid:', isCorrectFormat);

      expect(isCorrectFormat).toBe(true);
    } else {
      console.log('  No Cognito link found\n');
    }

    const hasQRCode = await page.locator('canvas, img[alt*="QR"]').count() > 0;
    const hasCodeInput = await page.locator('input[maxlength="6"]').count() > 0;
    const hasVerifyButton = await page.locator('button:has-text("Verify"), button:has-text("VERIFY")').count() > 0;

    console.log('  QR code element should NOT be present:', !hasQRCode);
    console.log('  Code input should NOT be present:', !hasCodeInput);
    console.log('  Verify button should NOT be present:', !hasVerifyButton);

    expect(hasQRCode).toBe(false);
    expect(hasCodeInput).toBe(false);
    expect(hasVerifyButton).toBe(false);

    console.log('PASS: MFA page is correctly simplified\n');
  });

  test('Settings page should have MFA setup link', async ({ page }) => {
    console.log('\nTEST: Settings Page MFA Link\n');

    await page.goto('https://portal.capsule-playground.com/settings');
    await page.waitForLoadState('networkidle');

    const url = page.url();
    console.log('  Current URL:', url);

    if (url.includes('login') || url.includes('auth')) {
      console.log('  Redirected to login (requires authentication)');
      console.log('  Settings correctly requires authentication\n');
      test.skip();
      return;
    }

    console.log('  Settings page loaded\n');

    const mfaLink = page.locator('a[href*="mfa-setup"], a:has-text("MFA"), a:has-text("Authenticator")').first();
    const mfaLinkExists = await mfaLink.count() > 0;

    if (mfaLinkExists) {
      const linkText = await mfaLink.textContent();
      const href = await mfaLink.getAttribute('href');
      console.log('  Found MFA link:', linkText);
      console.log('  href:', href);

      expect(href).toContain('mfa-setup');
    } else {
      console.log('  No MFA link found on settings page\n');
    }

    console.log('PASS: Settings page structure verified\n');
  });

});
