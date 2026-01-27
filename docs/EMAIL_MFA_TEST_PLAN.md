# Email MFA Test Plan

## Overview

This document outlines the complete test strategy for the email-based MFA system using AWS Cognito custom authentication flow.

## Test Pyramid

```
                    ┌─────────────────┐
                    │   E2E Tests     │  ← 5 tests
                    │   (Playwright)  │
                    └─────────────────┘
                  ┌────────────────────┐
                  │ Integration Tests  │  ← 10 tests
                  │ (Lambda + Cognito) │
                  └────────────────────┘
              ┌──────────────────────────┐
              │     Unit Tests           │  ← 15 tests
              │ (Lambda functions)       │
              └──────────────────────────┘
```

---

## 1. Unit Tests - Lambda Functions

### 1.1 DefineAuthChallenge Lambda

**File:** `tests/lambda/test_define_auth_challenge.py`

#### Test Cases:

1. **test_first_attempt_no_session**
   - Input: Empty session array
   - Expected: Issue SRP_A challenge (password)
   - Validates: Initial authentication request

2. **test_second_attempt_password_correct**
   - Input: Session with successful SRP_A
   - Expected: Issue CUSTOM_CHALLENGE (email MFA)
   - Validates: Password validated, MFA required

3. **test_second_attempt_password_incorrect**
   - Input: Session with failed SRP_A
   - Expected: failAuthentication = True
   - Validates: Wrong password rejection

4. **test_third_attempt_mfa_correct**
   - Input: Session with successful CUSTOM_CHALLENGE
   - Expected: issueTokens = True
   - Validates: MFA validated, grant access

5. **test_third_attempt_mfa_incorrect**
   - Input: Session with failed CUSTOM_CHALLENGE
   - Expected: failAuthentication = True
   - Validates: Wrong MFA code rejection

6. **test_too_many_attempts**
   - Input: Session with 4+ attempts
   - Expected: failAuthentication = True
   - Validates: Rate limiting

---

### 1.2 CreateAuthChallenge Lambda

**File:** `tests/lambda/test_create_auth_challenge.py`

#### Test Cases:

1. **test_generate_6_digit_code**
   - Expected: Code is exactly 6 digits
   - Validates: Code format

2. **test_code_randomness**
   - Generate 100 codes
   - Expected: All unique (or 99%+ unique)
   - Validates: Sufficient entropy

3. **test_store_in_dynamodb**
   - Mock DynamoDB
   - Expected: put_item called with correct schema
   - Validates: Code persistence

4. **test_ttl_is_5_minutes**
   - Expected: TTL timestamp is ~5 minutes from now
   - Validates: Expiration time

5. **test_send_email_via_ses**
   - Mock SES client
   - Expected: send_email called with correct parameters
   - Validates: Email delivery

6. **test_email_template_content**
   - Expected: Email contains code, expiration notice
   - Validates: User-facing message

7. **test_public_parameters_no_code**
   - Expected: publicChallengeParameters doesn't include code
   - Validates: Security (no code leak to client)

8. **test_private_parameters_has_code**
   - Expected: privateChallengeParameters includes code
   - Validates: Code available for verification

9. **test_challenge_metadata**
   - Expected: challengeMetadata = "EMAIL_MFA_CODE"
   - Validates: Challenge type identification

10. **test_ses_error_handling**
    - Mock SES to raise exception
    - Expected: Lambda doesn't crash
    - Validates: Graceful degradation

---

### 1.3 VerifyAuthChallenge Lambda

**File:** `tests/lambda/test_verify_auth_challenge.py`

#### Test Cases:

1. **test_correct_code**
   - Input: Code matches expected
   - Expected: answerCorrect = True
   - Validates: Valid code acceptance

2. **test_incorrect_code**
   - Input: Code doesn't match
   - Expected: answerCorrect = False
   - Validates: Invalid code rejection

3. **test_code_with_whitespace**
   - Input: " 123456 " (with spaces)
   - Expected: answerCorrect = True (after strip)
   - Validates: Whitespace tolerance

4. **test_delete_code_after_success**
   - Mock DynamoDB
   - Expected: delete_item called
   - Validates: Single-use codes

5. **test_no_delete_after_failure**
   - Mock DynamoDB
   - Expected: delete_item NOT called on wrong code
   - Validates: Code remains for retry

6. **test_empty_code**
   - Input: Empty string
   - Expected: answerCorrect = False
   - Validates: Input validation

---

## 2. Integration Tests - AWS Services

### 2.1 DynamoDB Operations

**File:** `tests/integration/test_dynamodb_mfa_codes.py`

#### Test Cases:

1. **test_create_code_entry**
   - Write to actual DynamoDB table
   - Expected: Item created
   - Validates: Table writable

2. **test_read_code_entry**
   - Write then read code
   - Expected: Data matches
   - Validates: Table readable

3. **test_ttl_expiration**
   - Create item with TTL in past
   - Wait for TTL processor (~15 minutes)
   - Expected: Item deleted
   - Validates: TTL functionality

4. **test_delete_code**
   - Create then delete item
   - Expected: Item gone
   - Validates: Deletion works

---

### 2.2 SES Email Delivery

**File:** `tests/integration/test_ses_email_delivery.py`

#### Test Cases:

1. **test_send_to_verified_email**
   - Send email via SES
   - Expected: MessageId returned
   - Validates: Email sending works

2. **test_email_received**
   - Send email, check inbox (if possible)
   - Expected: Email arrives within 30 seconds
   - Validates: End-to-end delivery

3. **test_email_content_format**
   - Parse received email
   - Expected: Contains 6-digit code
   - Validates: Template rendering

4. **test_sandbox_restrictions**
   - Try sending to unverified email
   - Expected: Error (if in sandbox)
   - Validates: SES mode detection

---

### 2.3 Cognito Custom Auth Flow

**File:** `tests/integration/test_cognito_custom_auth.py`

#### Test Cases:

1. **test_initiate_auth_triggers_define**
   - Call Cognito initiateAuth
   - Expected: DefineAuthChallenge Lambda invoked
   - Validates: Lambda trigger configured

2. **test_correct_password_triggers_create**
   - Submit valid password
   - Expected: CreateAuthChallenge Lambda invoked
   - Validates: MFA challenge issued

3. **test_wrong_password_no_mfa**
   - Submit invalid password
   - Expected: Authentication fails, no MFA
   - Validates: Password validation first

4. **test_respond_to_mfa_challenge**
   - Submit MFA code
   - Expected: VerifyAuthChallenge Lambda invoked
   - Validates: Challenge response flow

5. **test_correct_mfa_issues_tokens**
   - Submit correct MFA code
   - Expected: Receive IdToken, AccessToken, RefreshToken
   - Validates: Successful authentication

6. **test_wrong_mfa_fails**
   - Submit incorrect MFA code
   - Expected: Authentication fails
   - Validates: MFA validation

---

## 3. End-to-End Tests - User Flows

### 3.1 Happy Path - Complete Authentication

**File:** `tests/playwright/tests/email-mfa-happy-path.spec.js`

#### Test Scenario:

```
User: dmar@capsule.com
Password: SecurePass123!
MFA: Email code
Expected: Access granted to portal
```

#### Steps:

1. Navigate to portal
2. Click "Sign In"
3. Enter email and password
4. Receive email with code
5. Enter MFA code
6. Access granted
7. Verify portal home page loads

---

### 3.2 Wrong Password Flow

**File:** `tests/playwright/tests/email-mfa-wrong-password.spec.js`

#### Test Scenario:

```
User: dmar@capsule.com
Password: WrongPassword123!
Expected: Authentication fails, no email sent
```

#### Steps:

1. Navigate to portal
2. Click "Sign In"
3. Enter email and WRONG password
4. Submit
5. Verify error message
6. Verify no email sent (check CloudWatch logs)

---

### 3.3 Wrong MFA Code Flow

**File:** `tests/playwright/tests/email-mfa-wrong-code.spec.js`

#### Test Scenario:

```
User: dmar@capsule.com
Password: SecurePass123! (correct)
MFA: 000000 (wrong)
Expected: MFA fails, can retry
```

#### Steps:

1. Navigate and login with correct password
2. Receive email with code
3. Enter WRONG code (000000)
4. Submit
5. Verify error message
6. Verify can retry
7. Enter correct code
8. Access granted

---

### 3.4 Expired MFA Code Flow

**File:** `tests/playwright/tests/email-mfa-expired-code.spec.js`

#### Test Scenario:

```
User: dmar@capsule.com
Password: SecurePass123!
MFA: Wait 6 minutes then submit code
Expected: Code expired error
```

#### Steps:

1. Navigate and login with correct password
2. Receive email with code
3. Wait 6 minutes (DynamoDB TTL)
4. Try to submit code
5. Verify "expired" error
6. Request new code
7. Submit new code
8. Access granted

---

### 3.5 Settings Page Shows Email MFA

**File:** `tests/playwright/tests/email-mfa-settings-page.spec.js`

#### Test Scenario:

```
Verify settings page correctly displays email MFA status
```

#### Steps:

1. Authenticate (with email MFA)
2. Navigate to /settings
3. Verify page loads
4. Verify "Email MFA" section present
5. Verify status shows "ACTIVE"
6. Verify no TOTP setup button
7. Verify password change button present

---

## 4. Regression Tests - Existing Features

### 4.1 Password Reset Still Works

**File:** `tests/playwright/tests/password-reset-with-email-mfa.spec.js`

#### Test Scenario:

```
Password reset flow should work independently of MFA
```

#### Steps:

1. Navigate to /logout-and-reset
2. Enter email
3. Receive password reset code
4. Submit code
5. Set new password
6. Login with new password
7. Complete MFA challenge
8. Access granted

---

### 4.2 Logout Still Works

**File:** `tests/playwright/tests/logout-with-email-mfa.spec.js`

#### Test Scenario:

```
Logout should clear session and require re-auth
```

#### Steps:

1. Login with email MFA
2. Navigate to /logout
3. Verify redirected to logged-out page
4. Try accessing /settings
5. Verify redirected to login
6. Must complete full auth flow again

---

## 5. Security Tests

### 5.1 Code Reuse Prevention

**File:** `tests/security/test_code_reuse.py`

#### Test Cases:

1. **test_code_deleted_after_use**
   - Submit valid code
   - Try submitting same code again
   - Expected: Second attempt fails

2. **test_code_single_use**
   - Generate code
   - Verify in DynamoDB
   - Use code
   - Verify deleted from DynamoDB

---

### 5.2 Rate Limiting

**File:** `tests/security/test_rate_limiting.py`

#### Test Cases:

1. **test_too_many_wrong_codes**
   - Submit 5 wrong codes
   - Expected: Account locked or CAPTCHA required
   - Validates: Brute force prevention

2. **test_too_many_password_attempts**
   - Submit 5 wrong passwords
   - Expected: Account locked
   - Validates: Cognito rate limiting

---

### 5.3 Code Complexity

**File:** `tests/security/test_code_complexity.py`

#### Test Cases:

1. **test_code_length**
   - Expected: 6 digits (1 million combinations)
   - Validates: Sufficient entropy

2. **test_code_randomness**
   - Generate 10,000 codes
   - Check distribution
   - Expected: Uniform distribution
   - Validates: No patterns

---

## 6. Performance Tests

### 6.1 Lambda Cold Start

**File:** `tests/performance/test_lambda_cold_start.py`

#### Test Cases:

1. **test_define_cold_start_time**
   - Invoke after 10+ minutes idle
   - Expected: < 3 seconds
   - Validates: Acceptable cold start

2. **test_create_cold_start_time**
   - Invoke after idle (includes SES)
   - Expected: < 5 seconds
   - Validates: Email sending performance

---

### 6.2 End-to-End Latency

**File:** `tests/performance/test_e2e_latency.py`

#### Test Cases:

1. **test_full_auth_flow_time**
   - Start: Click "Sign In"
   - End: Portal loads
   - Expected: < 10 seconds (excluding email delivery)
   - Validates: User experience

2. **test_email_delivery_time**
   - Trigger MFA
   - Measure time until email received
   - Expected: < 5 seconds
   - Validates: SES performance

---

## 7. Monitoring Tests

### 7.1 CloudWatch Logs

**File:** `tests/monitoring/test_cloudwatch_logs.py`

#### Test Cases:

1. **test_lambda_logs_created**
   - Invoke Lambda
   - Expected: Log stream created
   - Validates: Logging configured

2. **test_log_retention**
   - Expected: 7-day retention
   - Validates: Cost optimization

---

### 7.2 CloudWatch Metrics

**File:** `tests/monitoring/test_cloudwatch_metrics.py`

#### Test Cases:

1. **test_lambda_invocation_metric**
   - Invoke Lambda
   - Check CloudWatch metric
   - Expected: Invocation count increased
   - Validates: Metrics publishing

2. **test_lambda_error_metric**
   - Trigger Lambda error
   - Check error metric
   - Expected: Error count increased
   - Validates: Error tracking

---

## 8. Test Execution Strategy

### 8.1 Local Development

```bash
# Unit tests (fast, no AWS)
cd tests/lambda
pytest test_*.py -v

# Integration tests (requires AWS)
cd tests/integration
pytest test_*.py -v --aws-profile=dev

# E2E tests (requires deployed infrastructure)
cd tests/playwright
npm test
```

### 8.2 CI/CD Pipeline

```yaml
stages:
  - unit-tests          # Run on every commit
  - integration-tests   # Run on PR
  - deploy-staging      # Deploy to staging
  - e2e-tests          # Run against staging
  - deploy-production   # Deploy to production
  - smoke-tests        # Quick validation
```

### 8.3 Test Data Management

**Test Users:**
- `test-user-1@capsule.com` - Standard user
- `test-user-2@capsule.com` - Admin user
- `test-user-expired@capsule.com` - For expired code tests

**Test Cleanup:**
- DynamoDB: Delete test codes after each test
- SES: Use test mode or sandbox
- Cognito: Use separate test user pool

---

## 9. Test Coverage Goals

| Component | Unit | Integration | E2E | Total |
|-----------|------|-------------|-----|-------|
| Lambda Functions | 90% | - | - | 90% |
| DynamoDB Ops | - | 80% | - | 80% |
| SES Delivery | - | 70% | - | 70% |
| Cognito Flow | - | 85% | 95% | 90% |
| **Overall** | **85%** | **78%** | **90%** | **84%** |

---

## 10. Success Criteria

### Must Pass (Blockers):

- ✅ All unit tests pass
- ✅ DefineAuthChallenge correctly orchestrates flow
- ✅ CreateAuthChallenge sends email
- ✅ VerifyAuthChallenge validates codes
- ✅ Codes expire after 5 minutes
- ✅ Codes are single-use
- ✅ Happy path E2E test passes

### Should Pass (Important):

- ⚠️ Wrong password handled correctly
- ⚠️ Wrong MFA code handled correctly
- ⚠️ Settings page shows email MFA status
- ⚠️ Password reset still works
- ⚠️ Performance < 10 seconds end-to-end

### Nice to Have (Informational):

- ℹ️ Rate limiting tests
- ℹ️ Security tests
- ℹ️ Performance benchmarks
- ℹ️ Monitoring tests

---

## 11. Known Test Limitations

### Limitation 1: Email Code Retrieval

**Issue:** Tests cannot automatically retrieve email codes

**Workarounds:**
1. Use AWS SES test mode (echoes messages)
2. Mock SES in integration tests
3. Use DynamoDB to retrieve code for testing
4. Manual code entry for E2E tests

### Limitation 2: Cognito Hosted UI

**Issue:** Cognito hosted UI doesn't show custom challenges

**Impact:** E2E tests must use custom sign-in page or AWS SDK

**Solution:** Build custom sign-in page for testing

### Limitation 3: TTL Testing

**Issue:** DynamoDB TTL takes 15+ minutes to process

**Workarounds:**
1. Mock TTL expiration
2. Run long-running tests separately
3. Use manual deletion to simulate expiration

---

## 12. Test Maintenance

### Weekly:
- Review test pass/fail rates
- Update test data
- Check for flaky tests

### Monthly:
- Review test coverage
- Add tests for new features
- Remove obsolete tests
- Update performance baselines

### Quarterly:
- Full regression suite
- Security audit tests
- Load testing
- Disaster recovery tests

---

## Appendix A: Test File Structure

```
tests/
├── lambda/                           # Unit tests
│   ├── test_define_auth_challenge.py
│   ├── test_create_auth_challenge.py
│   └── test_verify_auth_challenge.py
├── integration/                      # Integration tests
│   ├── test_dynamodb_mfa_codes.py
│   ├── test_ses_email_delivery.py
│   └── test_cognito_custom_auth.py
├── playwright/                       # E2E tests
│   └── tests/
│       ├── email-mfa-happy-path.spec.js
│       ├── email-mfa-wrong-password.spec.js
│       ├── email-mfa-wrong-code.spec.js
│       ├── email-mfa-expired-code.spec.js
│       ├── email-mfa-settings-page.spec.js
│       ├── password-reset-with-email-mfa.spec.js
│       └── logout-with-email-mfa.spec.js
├── security/                         # Security tests
│   ├── test_code_reuse.py
│   ├── test_rate_limiting.py
│   └── test_code_complexity.py
├── performance/                      # Performance tests
│   ├── test_lambda_cold_start.py
│   └── test_e2e_latency.py
└── monitoring/                       # Monitoring tests
    ├── test_cloudwatch_logs.py
    └── test_cloudwatch_metrics.py
```

---

## Appendix B: Test Execution Commands

### Run All Tests
```bash
# Run everything (takes ~30 minutes)
./run-all-tests.sh
```

### Run by Category
```bash
# Unit tests only (fast)
pytest tests/lambda/ -v

# Integration tests (requires AWS)
pytest tests/integration/ -v

# E2E tests (requires deployed app)
cd tests/playwright && npm test

# Security tests
pytest tests/security/ -v

# Performance tests
pytest tests/performance/ -v
```

### Run Specific Test
```bash
# Single test file
pytest tests/lambda/test_define_auth_challenge.py -v

# Single test case
pytest tests/lambda/test_define_auth_challenge.py::test_first_attempt_no_session -v

# Single Playwright test
npx playwright test email-mfa-happy-path
```

---

## Appendix C: CI/CD Integration

### GitHub Actions Example

```yaml
name: Email MFA Tests

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Set up Python
        uses: actions/setup-python@v2
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: pip install pytest boto3 moto
      - name: Run unit tests
        run: pytest tests/lambda/ -v

  integration-tests:
    needs: unit-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-west-2
      - name: Run integration tests
        run: pytest tests/integration/ -v

  e2e-tests:
    needs: integration-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install Playwright
        run: |
          npm install
          npx playwright install
      - name: Run E2E tests
        run: cd tests/playwright && npm test
```
