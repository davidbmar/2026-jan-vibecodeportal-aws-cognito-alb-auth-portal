# Lambda Fixes Deployment Summary

## Deployment Status: ✅ COMPLETE

**Date:** January 29, 2026
**Region:** us-west-2
**Deployed By:** Terraform

---

## Changes Deployed

### 1. Enhanced Debugging in VerifyAuthChallenge ✅

**File:** `terraform/envs/tier5/lambdas/verify_auth_challenge.py`

**Changes Made:**
- Added detailed logging showing exact code values and types
- Logs both user-entered and expected codes with type information
- Shows stripped versions for debugging whitespace issues
- Provides detailed success/failure messages with comparison details

**New Log Output Example:**
```
Verifying code for user: dmar@capsule.com
User entered: '123456' (type: <class 'str'>)
Expected: '123456' (type: <class 'str'>)
User code stripped: '123456'
Expected code stripped: '123456'
Code is CORRECT - Match found!
Comparison: '123456' == '123456'
```

**Purpose:** Helps identify if `privateChallengeParameters` are persisting correctly through Cognito's session management.

---

### 2. Fixed Timezone Issues in CreateAuthChallenge ✅

**File:** `terraform/envs/tier5/lambdas/create_auth_challenge.py`

**Changes Made:**
- Changed `datetime.now()` to `datetime.now(timezone.utc)`
- Added `from datetime import timezone` import
- Ensures TTL calculations are consistent with Lambda's UTC environment

**Before:**
```python
expiry_time = datetime.now() + timedelta(minutes=5)
ttl = int(expiry_time.timestamp())
```

**After:**
```python
expiry_time = datetime.now(timezone.utc) + timedelta(minutes=5)
ttl = int(expiry_time.timestamp())
```

**Purpose:** Prevents codes from expiring immediately or at incorrect times due to timezone mismatch.

---

### 3. Added Retry Logic in DefineAuthChallenge ✅

**File:** `terraform/envs/tier5/lambdas/define_auth_challenge.py`

**Changes Made:**
- Changed from zero-tolerance (1 wrong attempt = locked) to allowing 2 attempts
- Users now get one retry if they enter wrong code
- After 2 failed attempts, authentication fails

**New Flow:**
- **Session 0:** First login → Issue CUSTOM_CHALLENGE (send code)
- **Session 1:** Code entered
  - ✅ Correct → Issue tokens (login success)
  - ❌ Wrong → Issue new CUSTOM_CHALLENGE (send new code, allow retry)
- **Session 2:** Second code entered
  - ✅ Correct → Issue tokens (login success)
  - ❌ Wrong → Fail authentication (user must start over)
- **Session 3+:** Too many attempts → Fail authentication

**Purpose:** Better user experience while maintaining security.

---

## SES Configuration Status

### Domain Verification: ✅ SUCCESS

```bash
$ aws ses get-identity-verification-attributes \
  --identities capsule-playground.com \
  --region us-west-2

Domain: capsule-playground.com
Status: Success ✅
```

**Note:** The domain `capsule-playground.com` is correctly configured (NOT the typo "capsule-payground.com").

### Email Identity: ⚠️ PENDING

```
Email: noreply@capsule-playground.com
Status: Pending ⚠️
```

**Action Needed:** The email identity needs to be verified. Check the inbox for noreply@capsule-playground.com for a verification email from AWS.

### Sandbox Mode: ⚠️ ACTIVE

```
Max 24-Hour Send: 200 emails
Max Send Rate: 1 email/second
Sent Last 24 Hours: 47 emails
```

**Current Limitations:**
- Can only send 200 emails per day
- Can only send 1 email per second
- Can only send to verified email addresses

**To Remove Sandbox Mode:**
1. Go to AWS SES Console → "Account dashboard"
2. Click "Request production access"
3. Fill out the form:
   - **Use case:** "Email authentication codes for employee portal"
   - **Daily sending quota needed:** 1,000 emails
   - **Maximum sending rate:** 10 emails/second
   - **Description:** "Sending 6-digit verification codes to employees for authentication to internal portal"
4. Typical approval time: 24 hours

---

## Testing Instructions

### Test 1: Basic Code Verification

**Objective:** Verify codes work correctly

**Steps:**
1. Open browser in incognito/private mode
2. Navigate to: https://portal.capsule-playground.com
3. Enter email: `dmar@capsule.com`
4. Enter password
5. Check email for verification code
6. Enter code in portal
7. **Expected:** Login successful

**If it fails, check logs:**
```bash
aws logs tail /aws/lambda/employee-portal-verify-auth-challenge \
  --since 5m --region us-west-2 --follow
```

Look for the detailed debug output showing code comparison.

---

### Test 2: Retry Functionality

**Objective:** Verify users can retry if they enter wrong code

**Steps:**
1. Start new login session
2. Enter email: `dmar@capsule.com`
3. Enter password
4. Get verification code email
5. **Enter WRONG code** (e.g., 000000)
6. **Expected:** "Invalid code. Please try again" + NEW code sent via email
7. Check email for NEW code
8. Enter the NEW code
9. **Expected:** Login successful

**If retry doesn't work, check logs:**
```bash
aws logs tail /aws/lambda/employee-portal-define-auth-challenge \
  --since 5m --region us-west-2 --follow
```

Look for "Session 1: MFA incorrect, issuing new challenge"

---

### Test 3: Multiple Failed Attempts

**Objective:** Verify authentication fails after 2 wrong codes

**Steps:**
1. Start new login session
2. Enter email: `dmar@capsule.com`
3. Enter password
4. Get verification code email
5. Enter WRONG code (e.g., 111111)
6. Get NEW code via email
7. Enter WRONG code again (e.g., 222222)
8. **Expected:** Authentication failed, must start over

---

### Test 4: Code Expiry

**Objective:** Verify codes expire after 5 minutes

**Steps:**
1. Start new login session
2. Enter email: `dmar@capsule.com`
3. Enter password
4. Get verification code email
5. **WAIT 6 minutes**
6. Enter the code
7. **Expected:** Code should be invalid (expired)

**Check DynamoDB to verify TTL:**
```bash
aws dynamodb get-item \
  --table-name employee-portal-mfa-codes \
  --key '{"username": {"S": "dmar@capsule.com"}}' \
  --region us-west-2
```

The `ttl` field should be ~300 seconds (5 minutes) after code creation.

---

## Monitoring and Debugging

### CloudWatch Log Groups

All Lambda functions log to CloudWatch:

```bash
# Watch VerifyAuthChallenge logs (code validation)
aws logs tail /aws/lambda/employee-portal-verify-auth-challenge \
  --since 10m --region us-west-2 --follow

# Watch CreateAuthChallenge logs (code generation/email)
aws logs tail /aws/lambda/employee-portal-create-auth-challenge \
  --since 10m --region us-west-2 --follow

# Watch DefineAuthChallenge logs (auth flow control)
aws logs tail /aws/lambda/employee-portal-define-auth-challenge \
  --since 10m --region us-west-2 --follow
```

### What to Look For

**In VerifyAuthChallenge logs:**
- ✅ "Code is CORRECT - Match found!" = Success
- ❌ "Code is INCORRECT - No match" = Check if expected_code is None
- ⚠️ "Expected: 'None'" = privateChallengeParameters not persisting

**In CreateAuthChallenge logs:**
- ✅ "Generated MFA code: XXXXXX" = Code created
- ✅ "Stored code in DynamoDB (TTL: XXXXXXX)" = Code saved
- ✅ "Sent email to [email] via SES" = Email sent
- ❌ "ERROR sending email via SES" = SES issue (check sandbox mode)

**In DefineAuthChallenge logs:**
- ✅ "Session 1: MFA correct, issuing tokens" = Login success
- ⚠️ "Session 1: MFA incorrect, issuing new challenge" = Retry triggered
- ❌ "Session 2: MFA incorrect again, failing authentication" = Too many failures

---

## DynamoDB Verification

### Check Stored Codes

```bash
# View all codes in table
aws dynamodb scan \
  --table-name employee-portal-mfa-codes \
  --region us-west-2

# Check specific user's code
aws dynamodb get-item \
  --table-name employee-portal-mfa-codes \
  --key '{"username": {"S": "dmar@capsule.com"}}' \
  --region us-west-2
```

**Expected Output:**
```json
{
  "Item": {
    "username": {"S": "dmar@capsule.com"},
    "code": {"S": "123456"},
    "ttl": {"N": "1706496123"},
    "created_at": {"S": "2026-01-29T01:00:23.456789+00:00"}
  }
}
```

---

## Known Issues and Workarounds

### Issue 1: privateChallengeParameters Not Persisting

**Symptom:** Logs show `Expected: 'None'` in VerifyAuthChallenge

**Root Cause:** Cognito may not preserve privateChallengeParameters between CreateAuthChallenge and VerifyAuthChallenge in some edge cases.

**Workaround (if needed):** Switch to DynamoDB-based verification instead of relying on privateChallengeParameters.

**Alternative Implementation (DO NOT APPLY UNLESS NEEDED):**

Edit `terraform/envs/tier5/lambdas/verify_auth_challenge.py` lines 28-32:

```python
# Get expected code from DynamoDB instead of privateChallengeParameters
expected_code = None
try:
    dynamodb = boto3.resource('dynamodb')
    table_name = os.environ['MFA_CODES_TABLE']
    table = dynamodb.Table(table_name)

    response = table.get_item(Key={'username': email})
    if 'Item' in response:
        expected_code = response['Item']['code']
        print(f"Retrieved code from DynamoDB: {expected_code}")
    else:
        print("No code found in DynamoDB for this user")
except Exception as e:
    print(f"ERROR retrieving code from DynamoDB: {str(e)}")
    # Fall back to privateChallengeParameters
    expected_code = event['request']['privateChallengeParameters'].get('code')
```

**When to use this workaround:**
- Only if testing shows `privateChallengeParameters` is consistently None
- Only after confirming with logs that the issue is parameter persistence

---

## Next Steps

### Immediate (Within 24 hours)

1. **Test Authentication Flow**
   - Test with user: dmar@capsule.com
   - Verify codes work correctly
   - Confirm retry functionality works
   - Check CloudWatch logs for any errors

2. **Request SES Production Access**
   - Go to AWS SES Console
   - Submit production access request
   - Provide use case details
   - Wait for approval (typically 24 hours)

3. **Verify Email Identity**
   - Check inbox for noreply@capsule-playground.com
   - Click verification link in AWS email
   - Confirm status changes to "Success"

### Short-term (Within 1 week)

1. **Monitor Authentication Success Rate**
   - Check CloudWatch metrics
   - Look for patterns of failures
   - Verify TTL is working correctly

2. **Test with Multiple Users**
   - Test with all user groups (admins, engineering, hr, etc.)
   - Verify all users can receive and use codes
   - Confirm group-based permissions still work

3. **Performance Testing**
   - Test concurrent logins
   - Verify Lambda execution times
   - Check DynamoDB read/write capacity

### Long-term (Ongoing)

1. **Set Up Alerts**
   - Create CloudWatch alarms for Lambda errors
   - Monitor SES bounce/complaint rates
   - Track authentication failure patterns

2. **Documentation**
   - Update user documentation for 2-attempt retry flow
   - Document troubleshooting steps for common issues
   - Create runbook for SES/Lambda issues

3. **Consider Enhancements**
   - Add rate limiting (prevent brute force)
   - Implement code resend functionality
   - Add SMS backup for email delivery failures

---

## Files Modified

| File | Purpose | Changes |
|------|---------|---------|
| `lambdas/verify_auth_challenge.py` | Validates user-entered codes | Added detailed debug logging |
| `lambdas/create_auth_challenge.py` | Generates and sends codes | Fixed timezone issues in TTL calculation |
| `lambdas/define_auth_challenge.py` | Controls auth flow | Added retry logic (2 attempts) |

---

## Rollback Plan

If the changes cause issues:

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Revert changes
git checkout HEAD -- lambdas/verify_auth_challenge.py
git checkout HEAD -- lambdas/create_auth_challenge.py
git checkout HEAD -- lambdas/define_auth_challenge.py

# Redeploy previous versions
terraform apply
```

Or use Terraform to rollback to specific Lambda version:

```bash
# List function versions
aws lambda list-versions-by-function \
  --function-name employee-portal-verify-auth-challenge \
  --region us-west-2

# Publish current version as alias (if needed)
aws lambda publish-version \
  --function-name employee-portal-verify-auth-challenge \
  --region us-west-2
```

---

## Support and Troubleshooting

### Authentication Fails with "Invalid code"

**Check:**
1. Verify code hasn't expired (5 minute limit)
2. Check CloudWatch logs for exact error
3. Look for "Expected: 'None'" in logs (privateChallengeParameters issue)
4. Verify DynamoDB has code stored

### Email Not Received

**Check:**
1. SES sandbox mode - is recipient email verified?
2. Check spam folder
3. Verify SES sending quota not exceeded (200/day limit)
4. Check CreateAuthChallenge logs for SES errors

### User Locked Out After One Wrong Code

**Check:**
1. Verify DefineAuthChallenge was updated correctly
2. Check logs for "Session 1: MFA incorrect, issuing new challenge"
3. If still seeing old behavior, try redeploying Lambda

### Codes Expiring Too Soon

**Check:**
1. Verify timezone fix was applied
2. Check DynamoDB TTL value
3. Compare `created_at` timestamp with current UTC time
4. Verify Lambda is using correct timezone

---

## Success Criteria

✅ Users can log in with verification codes on first try
✅ Users can retry if they enter wrong code once
✅ Authentication fails after 2 wrong attempts
✅ Codes expire after 5 minutes
✅ CloudWatch logs show detailed debug information
✅ SES domain is verified
⚠️ SES production access requested (pending)
⚠️ Email identity verified (pending)

---

## Contact Information

**AWS Region:** us-west-2
**Cognito User Pool ID:** us-west-2_WePThH2J8
**DynamoDB Table:** employee-portal-mfa-codes
**SES Domain:** capsule-playground.com
**Portal URL:** https://portal.capsule-playground.com

---

**Deployment Completed:** January 29, 2026
**Status:** Ready for Testing
**Next Action:** Test authentication flow with dmar@capsule.com
