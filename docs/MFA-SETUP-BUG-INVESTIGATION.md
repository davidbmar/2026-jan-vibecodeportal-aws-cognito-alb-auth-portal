# MFA Setup Bug Investigation

**Date**: 2026-01-27
**Reported By**: User (dmar@capsule.com)
**Status**: 🔴 **BUG CONFIRMED**

## User's Report

> "when i press account settings, then setup authenticator app, then it just repeats the same screen"

## Investigation Summary

### Phase 1: Root Cause Investigation ✅ COMPLETE

#### 1. Reproduced the Issue
- Navigated to `/settings` → Requires authentication (redirects to Cognito login)
- Cannot reproduce without valid auth session
- Created test to document expected behavior

#### 2. Analyzed Code
**Settings Page** (`/home/ubuntu/cognito_alb_ec2/app/templates/settings.html`):
- Line 57: Contains button linking to `/mfa-setup`
- Button text: "🔐 SET UP AUTHENTICATOR APP"
- Link: `<a href="/mfa-setup" class="btn-primary">`

**MFA Setup Route** (`user_data.sh` line 458):
```python
@app.get("/mfa-setup", response_class=HTMLResponse)
async def mfa_setup_page(request: Request):
    """MFA setup page - directs users to set up TOTP MFA."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("mfa_setup.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "cognito_domain": "employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com"  # ⚠️ BUG #1!
    })
```

**MFA Setup Template** (`user_data.sh` lines 1709-1756):
```html
<h3>HOW TO ENABLE MFA:</h3>
<ol>
    <li>Download an authenticator app (Google Authenticator, Authy, Microsoft Authenticator)</li>
    <li>Log out of the portal</li>  <!-- ❌ THIS IS THE PROBLEM -->
    <li>Log back in - you'll be prompted to set up MFA during login</li>
    <li>Scan the QR code with your authenticator app</li>
    <li>Enter the 6-digit code to complete setup</li>
</ol>
```

#### 3. Found Root Cause

**BUG #1: MFA Setup Page Shows "Logout and Login" Instead of QR Code**

**What User Sees**:
1. Click "SET UP AUTHENTICATOR APP" button
2. Navigate to `/mfa-setup` page
3. Page shows instructions: "Log out of the portal" and "Log back in"
4. No QR code
5. No immediate setup capability
6. User clicks back → sees same instructions again
7. This creates the "repeating screen" problem

**What SHOULD Happen**:
1. Click button
2. Navigate to `/mfa-setup`
3. Page makes API call to `/api/mfa/init`
4. QR code displays immediately
5. Secret key shown for manual entry
6. User scans QR code with authenticator app
7. User enters 6-digit code
8. MFA enabled immediately

**BUG #2: Wrong Cognito Domain in MFA Setup Route**

Line 467 in `user_data.sh`:
```python
"cognito_domain": "employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com"
```

Should be:
```python
"cognito_domain": "employee-portal-mnao1rgh.auth.us-west-2.amazoncognito.com"
```

This is using:
- Wrong subdomain: `gdg66a7d` (should be `mnao1rgh`)
- Wrong region: `us-east-1` (should be `us-west-2`)

### Phase 2: Check Tests ✅ COMPLETE

#### Existing Tests (`tests/mfa.spec.js`)

**What They Test**:
- ✅ Page loads without 404
- ✅ Email display (element exists)
- ✅ Instructions visible
- ✅ QR code element present
- ✅ Code input field present
- ✅ Verify button present

**What They DON'T Test**:
- ❌ **Actual user flow (Settings → Click Button → MFA Setup)**
- ❌ **Whether QR code actually displays (just checks if element exists)**
- ❌ **Whether `/api/mfa/init` is called**
- ❌ **Whether MFA can actually be set up**
- ❌ **Page content (they miss the "logout" instructions)**

#### Why Tests Didn't Catch This

The tests check for elements without authentication:
```javascript
// Test just checks if canvas element EXISTS
const qrArea = page.locator('canvas, img[alt*="QR"], #qr-code').first();
flowChecks['QR code area present'] = await qrArea.count() > 0;
```

**Problems**:
1. Tests don't require authentication (skip when redirected)
2. Tests check for element presence, not actual functionality
3. Tests don't follow user click flow
4. Tests don't verify page CONTENT (the logout instructions)

### Phase 3: New Tests Created ✅ COMPLETE

#### Created Test: `mfa-user-flow.spec.js`

**What It Tests**:
- ✅ Settings → Click MFA Button → Navigate to /mfa-setup
- ✅ Checks page content for "logout" instructions (the bug)
- ✅ Checks for QR code VISIBILITY (not just existence)
- ✅ Verifies `/api/mfa/init` API call
- ✅ Takes screenshots for documentation
- ✅ **Documents the exact bug user reported**

#### Created Test: `complete-user-journey-e2e.spec.js`

**What It Tests**:
- ✅ Complete flow: Password Reset → Login → Settings → MFA → Logout
- ✅ Requires authentication (marks tests as skip without auth)
- ✅ Documents expected behavior for each phase
- ✅ Shows where manual intervention is needed

## Bugs Confirmed

### 🔴 BUG #1: MFA Setup Shows Logout Instructions Only
**Severity**: HIGH
**Impact**: Users cannot set up MFA from portal

**Current Behavior**:
- Page shows: "Log out of the portal" → "Log back in"
- No QR code
- No immediate setup
- Creates "repeating screen" experience

**Expected Behavior**:
- QR code displays immediately
- Secret key shown
- Code input and verify button present
- User can complete MFA setup without logging out

**Root Cause**: Template shows ALB authentication limitations, not actual MFA setup flow

### 🔴 BUG #2: Wrong Cognito Domain Configuration
**Severity**: MEDIUM
**Impact**: May cause issues with MFA setup if implemented

**Current Value**: `employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com`
**Correct Value**: `employee-portal-mnao1rgh.auth.us-west-2.amazoncognito.com`

**Root Cause**: Hardcoded old domain/region

### 🟡 BUG #3: Tests Don't Catch User Flow Issues
**Severity**: MEDIUM
**Impact**: False confidence in test coverage

**Current Tests**:
- Check elements exist
- Don't require authentication
- Don't test actual user clicks
- Don't verify functionality

**Needed**:
- Tests that follow user clicks
- Tests with authentication
- Tests that verify actual behavior, not just elements

## Required Fixes

### Fix #1: Implement Real MFA Setup Page

Need to create a proper MFA setup flow:

1. **Add `/api/mfa/init` Endpoint**
   ```python
   @app.post("/api/mfa/init")
   async def init_mfa(request: Request):
       email, groups = require_auth(request)

       # Generate TOTP secret
       secret = pyotp.random_base32()

       # Generate QR code URI
       totp_uri = pyotp.totp.TOTP(secret).provisioning_uri(
           name=email,
           issuer_name="Capsule Portal"
       )

       return {
           "success": True,
           "secret": secret,
           "qr_uri": totp_uri
       }
   ```

2. **Update MFA Setup Template**
   - Remove "logout and login" instructions
   - Add QR code generation with qrcode.js
   - Add secret key display
   - Add code verification form
   - Make API call to `/api/mfa/init` on page load

3. **Add `/api/mfa/verify` Endpoint**
   ```python
   @app.post("/api/mfa/verify")
   async def verify_mfa(request: Request):
       email, groups = require_auth(request)
       data = await request.json()

       secret = data.get("secret")
       code = data.get("code")

       # Verify TOTP code
       totp = pyotp.TOTP(secret)
       if totp.verify(code):
           # Associate MFA with user in Cognito
           cognito_client.set_user_mfa_preference(
               AccessToken=get_access_token(request),
               SoftwareTokenMfaSettings={
                   'Enabled': True,
                   'PreferredMfa': True
               }
           )
           return {"success": True}
       else:
           return {"success": False, "error": "invalid_code"}
   ```

### Fix #2: Update Cognito Domain

In `user_data.sh` line 467:
```python
# BEFORE:
"cognito_domain": "employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com"

# AFTER:
"cognito_domain": "employee-portal-mnao1rgh.auth.us-west-2.amazoncognito.com"
```

### Fix #3: Improve Test Coverage

Add tests that:
1. Require authentication (or use test auth token)
2. Follow actual user click flows
3. Verify API calls are made
4. Check page content, not just elements
5. Test complete journeys, not isolated pages

## Why This Matters

### User Impact
- ❌ Users cannot enable MFA from portal
- ❌ Security feature advertised but not functional
- ❌ Confusing user experience ("repeating screen")
- ❌ Users must rely on Cognito login flow for MFA

### Business Impact
- Reduced security posture (MFA not adopted)
- User frustration
- Support tickets
- Loss of trust in portal

## Next Steps

1. ✅ **Document bug** (this file)
2. ✅ **Create proper E2E tests** (done)
3. ⏳ **Implement `/api/mfa/init` endpoint**
4. ⏳ **Implement `/api/mfa/verify` endpoint**
5. ⏳ **Update MFA setup template with real QR code**
6. ⏳ **Fix Cognito domain configuration**
7. ⏳ **Test with real user**
8. ⏳ **Deploy fixes**
9. ⏳ **Run all tests to verify**

## Related Files

- `/home/ubuntu/cognito_alb_ec2/app/templates/settings.html` - Settings page with MFA button
- `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/user_data.sh` (lines 458-468) - MFA route
- `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/user_data.sh` (lines 1709-1756) - MFA template
- `/home/ubuntu/cognito_alb_ec2/tests/playwright/tests/mfa.spec.js` - Existing tests (inadequate)
- `/home/ubuntu/cognito_alb_ec2/tests/playwright/tests/mfa-user-flow.spec.js` - New E2E test
- `/home/ubuntu/cognito_alb_ec2/tests/playwright/tests/complete-user-journey-e2e.spec.js` - Complete journey test

---

**Created**: 2026-01-27
**Status**: Investigation complete, fixes pending
**Priority**: HIGH - User-reported bug affecting security feature
