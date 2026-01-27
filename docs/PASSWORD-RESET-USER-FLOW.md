# Password Reset User Flow - Complete Guide

## Overview

This document explains the correct password reset flow and why users might encounter 401 errors if they deviate from the recommended path.

## The Problem: Two Different Password Reset Paths

Users can accidentally trigger two different password reset flows, which causes confusion:

### ❌ Wrong Path: Cognito Hosted UI (Causes 401 Error)

1. User clicks "Forgot your password?" on Cognito login page
2. User enters email and receives code
3. User resets password through Cognito
4. Cognito redirects to: `https://portal.capsule-playground.com/oauth2/idpresponse?code=...`
5. **ALB rejects with 401 Authorization Required** ❌

**Why this fails:**
- The OAuth callback requires a "state" token for CSRF protection
- When you bypass the ALB and go directly to Cognito, the ALB doesn't have a session to validate
- The authorization code cannot be validated without the matching state token
- This is SECURE behavior - the ALB is correctly rejecting unauthorized callbacks

### ✅ Correct Path: Custom Password Reset Flow

1. **From Settings Page:**
   - User clicks "CHANGE PASSWORD" button
   - Gets logged out and redirected to `/password-reset`

2. **Or from Logged Out State:**
   - User goes to https://portal.capsule-playground.com/password-reset

3. **Password Reset Process:**
   - Enter email address
   - Receive 6-digit verification code via email
   - Enter code and create new password
   - Success page displays with clear instructions

4. **Login with New Password:**
   - Click "LOGIN WITH NEW PASSWORD" button
   - Redirected to Cognito login page
   - Enter email and NEW password
   - Click "Sign in"
   - Successfully logged into portal ✅

## Why The Custom Flow Works

The custom flow avoids the OAuth callback issue:

1. Password reset happens through custom API endpoints
2. Success page redirects to portal home (`/`)
3. Portal home triggers ALB OAuth flow with proper state token
4. User authenticates at Cognito
5. Cognito redirects to OAuth callback WITH valid state token
6. ALB validates state token and completes authentication
7. User is logged in successfully

## Step-by-Step Instructions for Users

### Changing Your Password (When Logged In)

1. Click your profile or "Account Settings"
2. Click "CHANGE PASSWORD" button
3. You'll be logged out and see the password reset page
4. Enter your email address
5. Check your email for a 6-digit code
6. Enter the code on the password reset page
7. Create your new password (must meet all requirements)
8. You'll see a SUCCESS page with detailed instructions
9. Click "LOGIN WITH NEW PASSWORD"
10. On the Cognito login page:
    - Enter your email
    - Enter your NEW password (not the old one)
    - Click "Sign in"
11. You're back in the portal!

### Resetting Your Password (When Logged Out)

1. Go to https://portal.capsule-playground.com/password-reset
2. Follow steps 4-11 above

### ❌ Common Mistakes to Avoid

**DO NOT:**
- Click "Forgot your password?" on the Cognito login page
- Use your browser's back button after clicking "LOGIN WITH NEW PASSWORD"
- Try to manually navigate to `/oauth2/idpresponse` URLs
- Enter your old password after resetting

**DO:**
- Follow the custom password reset flow at `/password-reset`
- Read the instructions on the success page carefully
- Enter your NEW password when logging in after reset
- Clear your browser cookies if you encounter issues

## Technical Details

### OAuth Callback Protection

The ALB's OAuth flow includes CSRF protection via state tokens:

```
Secure Flow:
1. ALB generates secret state token and stores in session
2. ALB redirects to Cognito with state parameter
3. User authenticates
4. Cognito redirects back with code + state
5. ALB validates state matches → exchanges code for tokens
6. User authenticated ✅

Insecure Flow (Prevented):
1. User goes directly to Cognito (bypassing ALB)
2. Cognito redirects with code but NO state
3. ALB rejects: "I didn't initiate this flow" → 401 ❌
```

### Custom Password Reset API

Our custom flow uses these endpoints:

- `POST /api/password-reset/send-code` - Sends verification code via Cognito
- `POST /api/password-reset/verify-code` - Validates code format
- `POST /api/password-reset/confirm` - Confirms password reset with Cognito

These endpoints use Cognito's `forgot_password` and `confirm_forgot_password` APIs with proper SECRET_HASH computation.

## Troubleshooting

### Getting 401 Authorization Required

**Symptom:** After resetting password, you see "401 Authorization Required" at `/oauth2/idpresponse?code=...`

**Cause:** You used Cognito's "Forgot your password?" link instead of our custom reset flow

**Solution:**
1. Clear your browser cookies (or use incognito mode)
2. Go to https://portal.capsule-playground.com
3. This will trigger the ALB OAuth flow properly
4. Login with your NEW password
5. You should be able to access the portal

### Password Reset Code Not Arriving

**Symptom:** Not receiving verification code email

**Solution:**
1. Check your spam folder
2. Wait 1-2 minutes (email delivery can be slow)
3. Try the "Resend" link after 60 seconds
4. Verify you entered the correct email address

### Getting Rate Limited

**Symptom:** "Too many requests. Please try again later."

**Cause:** Cognito has rate limits on password reset attempts

**Solution:**
1. Wait 5-10 minutes before trying again
2. This is a security feature to prevent abuse
3. If you need immediate access, contact an administrator

## Security Features

Our password reset flow includes:

- ✅ Email verification required (code sent to registered email)
- ✅ 6-digit verification codes with 1-hour expiration
- ✅ Rate limiting to prevent brute force attacks
- ✅ Strong password requirements enforced
- ✅ Cognito SECRET_HASH for API authentication
- ✅ HTTPS encryption for all traffic
- ✅ OAuth state token validation by ALB
- ✅ Single-use authorization codes

## For Administrators

### Helping Users Who Are Stuck

If a user reports 401 errors:

1. Tell them to clear browser cookies or use incognito
2. Direct them to https://portal.capsule-playground.com/password-reset
3. Emphasize: Do NOT use "Forgot your password?" on Cognito login
4. Walk them through the custom password reset flow

### Monitoring Password Resets

Check application logs for password reset activity:
```bash
ssh ubuntu@<instance-ip>
sudo journalctl -u app.service -f | grep password-reset
```

### Manual Password Reset (Emergency)

As an administrator, you can manually reset a user's password:

```bash
aws cognito-idp admin-set-user-password \
  --user-pool-id us-west-2_WePThH2J8 \
  --username user@example.com \
  --password NewTemporaryPassword123! \
  --permanent \
  --region us-west-2
```

Then tell the user to login with the temporary password and immediately change it.

## Summary

**For Users:** Always use the custom password reset page at `/password-reset` and follow the on-screen instructions carefully.

**For Admins:** Educate users about the correct flow and help them avoid the Cognito "Forgot your password?" link.

**Security:** The 401 errors are actually a GOOD thing - they indicate the ALB is correctly rejecting unauthorized OAuth callbacks.
