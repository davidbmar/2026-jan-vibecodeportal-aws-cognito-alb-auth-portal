# Custom Password Reset Flow Design

**Date:** 2026-01-26
**Status:** Approved
**Author:** Claude + User Collaboration

## Problem Statement

The current password reset flow redirects users to AWS Cognito's hosted UI, which displays confusing messaging:
- "Please enter the code from portal.capsule-playground.com" (unclear that code is in email)
- No clear explanation of which code is needed at which step
- Breaks the portal's cohesive retro terminal aesthetic
- Poor UX during MFA challenges after password reset

## Solution: Custom In-Portal Password Reset Flow

Build a custom password reset experience that keeps users within the portal and provides clear, step-by-step guidance.

## Design Decisions

### 1. Flow Structure: Progressive Disclosure (Single Page)
- All steps happen on one page (`/password-reset`)
- Sections reveal progressively as user completes each step
- Keeps user oriented ("I'm on the password reset page")
- Smooth transitions with CSS animations

### 2. Error Handling: Step Validation
- Validate each step before revealing the next section
- Server-side validation prevents progression with invalid data
- Clear error messages inline at each step
- Smart error detection: differentiate "expired code" vs "invalid code"

### 3. Code Expiration: Smart Detection
- Parse Cognito error responses to determine error type
- If expired: "Code expired. Send new code?"
- If invalid: "Incorrect code. Please check your email and try again."
- Always show "Didn't receive the code? Resend" option

### 4. Timing Display: Static Expiration Notice
- After sending code: "Code sent to your email. Valid for 1 hour."
- No countdown timer (reduces anxiety)
- Show 60-second cooldown for resend requests only

### 5. Password Guidance: Real-time Validation Checklist
- Show all requirements as checklist below password field
- ✓ Green checkmark as each requirement is met
- ✗ Red X for unmet requirements
- Requirements:
  - Minimum 8 characters
  - At least one uppercase letter
  - At least one lowercase letter
  - At least one number
  - At least one special character (!@#$%^&*)

### 6. Password Entry: Single Field with Show/Hide Toggle
- One password field (no confirmation field)
- Eye icon toggle: "👁 SHOW" / "👁 HIDE"
- Reduces friction while allowing visual verification

### 7. Success Flow: Manual Login Required
- Success page with clear confirmation message
- User manually logs in with new password
- Explicit re-authentication for security
- No auto-login to avoid session confusion

## Architecture

### Frontend: Progressive Disclosure Page

**Route:** `/password-reset`

**Three Sections:**

1. **Email Section** (initially visible)
   - Email input field
   - "SEND RESET CODE" button
   - Validates email format client-side
   - Submits to backend API

2. **Code Section** (revealed after email validated)
   - Success banner: "Code sent to {email}. Valid for 1 hour."
   - 6-digit code input field
   - "Didn't receive the code? Resend" link (60s cooldown)
   - "VERIFY CODE" button

3. **Password Section** (revealed after code verified)
   - New password field with show/hide toggle
   - Real-time validation checklist
   - "RESET PASSWORD" button

**Success Page:** `/password-reset-success`
- Confirmation message
- "RETURN TO LOGIN" button

### Backend: Three API Endpoints

**1. POST `/api/password-reset/send-code`**
```python
Input: { "email": "user@example.com" }
Process:
  - Call cognito_client.forgot_password(Username=email)
  - Returns delivery destination (masked email)
Output: { "success": true, "destination": "u***@example.com" }
Error: { "success": false, "error": "User not found" }
```

**2. POST `/api/password-reset/verify-code`**
```python
Input: { "email": "user@example.com", "code": "123456" }
Process:
  - Store email+code in session for final step
  - Verify code is valid format (6 digits)
  - Return success (don't actually verify with Cognito yet)
Output: { "success": true }
Error: { "success": false, "error": "Invalid code format" }
```

**3. POST `/api/password-reset/confirm`**
```python
Input: { "email": "user@example.com", "code": "123456", "password": "NewPass123!" }
Process:
  - Validate password against requirements
  - Call cognito_client.confirm_forgot_password(
      Username=email,
      ConfirmationCode=code,
      Password=password
    )
  - Parse Cognito errors for smart error detection
Output: { "success": true }
Errors:
  - { "success": false, "error": "expired", "message": "Code expired" }
  - { "success": false, "error": "invalid_code", "message": "Invalid code" }
  - { "success": false, "error": "weak_password", "message": "Password requirements not met" }
```

### State Management

**Client-Side:**
- Track current step (email, code, password)
- Store email in component state
- Track resend cooldown (60 seconds)
- Validate password requirements in real-time

**Server-Side:**
- Stateless API endpoints
- No session storage needed (email passed in each request)
- Cognito manages code validation and expiration

## Visual Design

### Section States

```
Initial:
  [✓] Email Section     (visible, enabled)
  [ ] Code Section      (hidden)
  [ ] Password Section  (hidden)

After Email:
  [✓] Email Section     (visible, disabled, opacity 0.6)
  [✓] Code Section      (visible, enabled, glowing border)
  [ ] Password Section  (hidden)

After Code:
  [✓] Email Section     (visible, disabled, opacity 0.6)
  [✓] Code Section      (visible, disabled, opacity 0.6)
  [✓] Password Section  (visible, enabled, glowing border)
```

### Styling
- Matches portal's retro CRT terminal aesthetic
- Green (#00ff00) for success states
- Yellow (#ffff00) for warnings
- Red (#ff0000) for errors
- Monospace font for code inputs
- ASCII art header: "RESET PASSWORD"
- Smooth CSS transitions (300ms slide + fade)

## Error Handling

### User Not Found
- Show: "No account found with that email address"
- Don't reveal whether email exists (security)
- Actually: Check if user exists, show generic error either way

### Code Errors
- **Expired:** "Your code has expired. Click 'Resend' to get a new code."
- **Invalid:** "Incorrect code. Please check your email and try again."
- **Too many attempts:** "Too many failed attempts. Please request a new code."

### Password Errors
- Show which requirements are not met in checklist
- "Password must meet all requirements above"

### Rate Limiting
- Resend cooldown: 60 seconds
- Show: "Please wait X seconds before requesting another code"
- Too many resends: "Too many requests. Please try again later."

## Testing Plan

### Manual Testing Steps
1. Request code with valid email
2. Verify code sent to email
3. Enter correct code, verify password section appears
4. Test password requirements (all variations)
5. Submit valid password, verify success page
6. Test expired code scenario
7. Test invalid code (3+ attempts)
8. Test resend functionality
9. Test password show/hide toggle
10. Verify redirect to login works

### Edge Cases
- Email doesn't exist in Cognito
- Code expires during entry
- Multiple resend requests
- Network errors during submission
- Browser back button behavior
- Session timeout

## Migration Plan

1. **Build new flow** (this design)
2. **Keep old flow temporarily** - don't remove `/password-reset-info` yet
3. **Test new flow** thoroughly
4. **Add A/B test** or gradual rollout if desired
5. **Monitor** error rates and completion rates
6. **Remove old flow** after validation
7. **Update Settings page** to point to new `/password-reset` route

## Security Considerations

- All passwords transmitted over HTTPS only
- Password never stored in browser state
- Code validation done server-side
- Rate limiting on resend requests
- Clear success/failure messages without revealing system details
- Force logout before allowing password reset
- No auto-login after reset (explicit re-authentication)

## Files to Create/Modify

### New Files
- `/opt/employee-portal/templates/password_reset.html` - Main flow page
- `/opt/employee-portal/templates/password_reset_success.html` - Success page
- `/opt/employee-portal/static/js/password-reset.js` - Client-side logic
- `/opt/employee-portal/static/css/password-reset.css` - Styling (if needed)

### Modified Files
- `/opt/employee-portal/app.py` - Add 3 API endpoints + 2 page routes
- `/opt/employee-portal/templates/settings.html` - Update link to new `/password-reset`
- User data script or deployment scripts to deploy changes

## Success Metrics

- **Completion rate:** % of users who complete the flow
- **Time to complete:** Average time from start to success
- **Error rate:** % of failed attempts per step
- **Support tickets:** Reduction in "can't reset password" tickets
- **User feedback:** Qualitative feedback on clarity

## Future Enhancements

- Add "Remember this device" option to skip MFA
- Email notification when password is changed
- Password strength recommendations
- Link to password managers
- Localization for multiple languages
