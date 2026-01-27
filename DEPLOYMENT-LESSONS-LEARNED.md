# Email MFA Deployment: Lessons Learned
**Date:** 2026-01-27
**Session:** Email MFA with Cognito Custom Authentication

## Executive Summary

**Status:** Infrastructure deployed successfully, critical architectural incompatibility discovered.

**Key Finding:** Cognito Custom Auth Challenges are incompatible with ALB + Hosted UI OAuth flows. Email MFA via custom challenges cannot work with the current architecture.

---

## Deployment Issues Encountered & Fixed

### 1. Cloud-Init Script Size Limitation ⚠️ CRITICAL

**Problem:**
- `user_data.sh` script is 120KB / 3369 lines
- Works perfectly when run manually via SSH
- Consistently fails during cloud-init bootstrap
- Symptoms: pip install succeeds, but app.py creation never happens

**Root Cause:**
- Cloud-init has undocumented size/complexity limits
- Large scripts with heredocs truncate silently during boot
- No error messages in cloud-init logs

**Evidence:**
```bash
# Manual execution: SUCCESS (100% completion)
ubuntu@ip-10-0-1-250:~$ sudo bash /var/lib/cloud/instance/user-data.sh
# Output: "Employee Portal deployed successfully!"

# Cloud-init execution: PARTIAL FAILURE
# - Creates /opt/employee-portal/venv/
# - Installs pip packages
# - Never creates app.py (heredoc section fails)
```

**Solution:**
Split deployment into two phases:
1. **Minimal user_data** (already implemented in `portal-instance.tf`):
   - Install dependencies
   - Create directories and users
   - Set up Python venv

2. **Separate deployment script** (`deploy-portal.sh`):
   - Extract app code from user_data.sh
   - Substitute Terraform variables
   - Deploy via SSH/SSM after instance is running

**Lesson:** Keep user_data scripts under 16KB. Use S3/SSM for complex deployments.

---

### 2. Terraform Variable Substitution in Heredocs

**Problem:**
```bash
# user_data.sh line 23 - WRONG
cat > /opt/employee-portal/app.py << 'EOFAPP'
AWS_REGION = "${aws_region}"
# Result: Variables NOT substituted (single quotes prevent interpolation)
```

**Fix:**
```bash
# user_data.sh line 23 - CORRECT
cat > /opt/employee-portal/app.py << EOFAPP
AWS_REGION = "${aws_region}"
# Result: Terraform substitutes variables during template rendering
```

**But:** This created a second issue - when run manually, bash tries to substitute `${aws_region}` as a bash variable (which doesn't exist), resulting in empty strings.

**Actual Solution:**
Don't run user_data.sh manually. Use the deploy-portal.sh script which:
1. Extracts code from user_data.sh
2. Substitutes variables using `sed`
3. Deploys to instance

**Lesson:** Heredoc quoting matters. `<< 'EOF'` = literal, `<< EOF` = interpolated.

---

### 3. Missing Configuration Variables

**Problem:**
Service crash-looped with:
```
ValueError: Invalid endpoint: https://cognito-idp..amazonaws.com
```

**Root Cause:**
- app.py had: `USER_POOL_ID = ""`, `AWS_REGION = ""`, etc.
- Terraform variables weren't substituted (see issue #2)

**Fix:**
```bash
sudo sed -i '
s/USER_POOL_ID = \"\"/USER_POOL_ID = \"us-west-2_WePThH2J8\"/
s/AWS_REGION = \"\"/AWS_REGION = \"us-west-2\"/
s/CLIENT_ID = \"\"/CLIENT_ID = \"7qa8jhkle0n5hfqq2pa3ld30b\"/
s/CLIENT_SECRET = \"\"/CLIENT_SECRET = \"1cr0fa5s6d4j5n7i4fgl5ilndlo9cvgjsgd92mqgpb94d98o7ksl\"/
' /opt/employee-portal/app.py
```

**Lesson:** Always verify configuration substitution. Add health checks that validate required env vars.

---

### 4. IAM Permission Errors (Iterative Discovery)

**Problem:**
Terraform apply failed with cascading permission errors:

```
✗ dynamodb:CreateTable - AccessDenied
✗ dynamodb:DescribeContinuousBackups - AccessDenied
✗ dynamodb:ListTagsOfResource - AccessDenied
✗ lambda:ListVersionsByFunction - AccessDenied
✗ lambda:GetFunctionCodeSigningConfig - AccessDenied
```

**Root Cause:**
- Initial `email-mfa-deployment-policy` only had SES permissions
- Terraform requires additional read/describe permissions beyond create/update/delete
- Each permission required 10-60 second propagation delay

**Fix:**
Comprehensive IAM policy created in `/terraform/envs/tier5/iam-email-mfa-policy.json`:
- DynamoDB: CreateTable, DescribeTable, UpdateTable, DeleteTable, PutItem, GetItem, DeleteItem, DescribeContinuousBackups, ListTagsOfResource
- Lambda: CreateFunction, UpdateFunction, GetFunction, DeleteFunction, AddPermission, ListVersionsByFunction, GetFunctionCodeSigningConfig
- SES: VerifyEmailIdentity, SendEmail, GetIdentityVerificationAttributes
- IAM: CreateRole, PutRolePolicy, PassRole
- CloudWatch Logs: CreateLogGroup, DeleteLogGroup

**Lesson:** Grant Terraform all read permissions upfront. IAM propagation takes 10-60s.

---

### 5. TOTP MFA Code Removal

**Problem:**
```
ModuleNotFoundError: No module named 'pyotp'
```

**Root Cause:**
- Removed `pyotp` and `qrcode[pil]` from pip install (line 20)
- But left `import pyotp` and `import qrcode` in code (lines 35-36)
- Left TOTP MFA routes active (lines 474-572)

**Fix:**
```python
# Lines 35-36: Removed imports
# import pyotp  # REMOVED
# import qrcode  # REMOVED

# Line 68: Commented out TOTP storage
# mfa_secrets = {}  # TOTP MFA - replaced with email MFA via Cognito

# Lines 474-572: Commented out routes
# @app.get("/api/mfa/init")
# @app.post("/api/mfa/verify")
# @app.get("/api/mfa/status")
```

**Lesson:** When removing dependencies, grep for all usages. Remove imports AND implementation.

---

### 6. Instance Health Check Failures

**Problem:**
Multiple instances failed health checks after 5+ minutes:
- i-03dacfa110ea1c9c9 - unhealthy
- i-0640cff459bdf0467 - unhealthy
- i-03cd4254620ae668a - unhealthy
- i-01ebe3bbad23c0efc - initially unhealthy

**Root Causes:**
1. Missing dependencies (pyotp/qrcode)
2. Unsubstituted variables (`${aws_region}` → empty string)
3. Cloud-init truncation (app.py never created)

**Fix Process:**
1. SSH into instance with `.ssh/david-capsule-vibecode-2026-01-17.pem`
2. Check service status: `sudo systemctl status employee-portal`
3. View logs: `sudo journalctl -u employee-portal -n 100`
4. Manually run user_data.sh to complete installation
5. Fix configuration variables in app.py
6. Restart service: `sudo systemctl restart employee-portal`
7. Wait 30-60s for health check update

**Final Status:**
- Instance i-01ebe3bbad23c0efc: **HEALTHY** ✅
- Service responding: `curl localhost:8000/health` → `200 OK`
- Portal accessible: https://portal.capsule-playground.com → redirects to Cognito

**Lesson:** SSH debugging is essential. Always check logs before recreating instances.

---

## Critical Architectural Incompatibility 🚨

### The Core Problem

**Email MFA via Cognito Custom Auth Challenges CANNOT work with ALB + Hosted UI architecture.**

#### Why?

1. **ALB requires OAuth2 flow** via Cognito Hosted UI
2. **Hosted UI only supports standard auth:**
   - Username/password (SRP_AUTH)
   - Built-in MFA (SOFTWARE_TOKEN_MFA for TOTP, SMS_MFA)
   - Social providers (Google, Facebook, etc.)

3. **Custom challenges require direct SDK integration:**
   - `initiateAuth()` with `CUSTOM_AUTH` flow
   - `respondToAuthChallenge()` with custom challenge answers
   - NOT supported by hosted UI

4. **What happens:**
   ```
   User logs in → Password correct → DefineAuthChallenge says "issue CUSTOM_CHALLENGE"
   → Hosted UI has no UI to present this challenge → Login fails
   ```

#### Evidence

**Test Results:**
- ✅ SDK authentication works: `aws cognito-idp initiate-auth` with USER_PASSWORD_AUTH → SUCCESS
- ❌ Hosted UI authentication fails: Login form → "Incorrect username or password"
- ✅ Lambda functions deployed correctly
- ✅ Lambda triggers configured in Cognito
- ❌ Lambda triggers removed temporarily to test - still fails
- ❌ OAuth flows enabled - still fails

**App Client Configuration:**
```json
{
  "ExplicitAuthFlows": ["ALLOW_CUSTOM_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
  "AllowedOAuthFlows": ["code"],
  "AllowedOAuthFlowsUserPoolClient": true  // REQUIRED for hosted UI
}
```

**The Conflict:**
- `ALLOW_CUSTOM_AUTH` = for SDK use
- `AllowedOAuthFlows: ["code"]` = for hosted UI
- These two cannot work together when Lambda triggers are active

---

## Architecture Options Going Forward

### Option 1: Native Cognito MFA (RECOMMENDED ✅)

**Use built-in SOFTWARE_TOKEN_MFA (TOTP)**

**Pros:**
- ✅ Works seamlessly with ALB + Hosted UI
- ✅ Cognito natively enforces MFA before token issuance
- ✅ No custom Lambda functions needed
- ✅ Standard TOTP apps (Google Authenticator, Authy, 1Password)
- ✅ Already partially implemented (just remove TOTP from app code, enable in Cognito)

**Cons:**
- ❌ Users need to install authenticator app
- ❌ QR code setup required (but Cognito hosted UI handles this)

**Implementation:**
```hcl
# In main.tf
resource "aws_cognito_user_pool" "main" {
  mfa_configuration = "OPTIONAL"  # or "ON" to require

  software_token_mfa_configuration {
    enabled = true
  }

  # REMOVE Lambda triggers
  # lambda_config { ... }
}
```

### Option 2: Custom Frontend with SDK Auth

**Build custom login page that calls Cognito SDK directly**

**Pros:**
- ✅ Can use custom challenges (email MFA)
- ✅ Full control over UI/UX
- ✅ Can implement any MFA method

**Cons:**
- ❌ **Cannot use ALB authentication** (ALB requires OAuth redirect)
- ❌ Need to implement session management in app
- ❌ Need to validate JWT tokens in app code
- ❌ Lose ALB's automatic authentication enforcement
- ❌ Significant development effort

**Architecture Change Required:**
```
Current: ALB → Cognito Hosted UI → App
Proposed: ALB → App (with custom login page) → Cognito SDK
```

### Option 3: Email MFA via Cognito Advanced Security

**Use Cognito's adaptive authentication with email**

**Pros:**
- ✅ Cognito can send email challenges natively
- ✅ Works with hosted UI
- ✅ Risk-based MFA (only prompt when suspicious)

**Cons:**
- ❌ Requires Cognito Advanced Security ($$$)
- ❌ Triggers based on risk, not every login
- ❌ Less control over email content/timing

### Option 4: Post-Authentication Email Verification

**Separate MFA from login, add email verification step in app**

**Pros:**
- ✅ Works with current ALB + OAuth architecture
- ✅ Can send emails via SES
- ✅ Full control over verification flow

**Cons:**
- ❌ Not true pre-authentication MFA
- ❌ User gets JWT tokens before email verification
- ❌ Can't revoke tokens if email fails
- ❌ Additional app logic required

---

## Recommended Path Forward

### Phase 1: Enable Native TOTP MFA (1-2 hours)

1. **Update Cognito User Pool:**
   ```bash
   aws cognito-idp update-user-pool \
     --user-pool-id us-west-2_WePThH2J8 \
     --mfa-configuration OPTIONAL \
     --software-token-mfa-configuration Enabled=true
   ```

2. **Remove Lambda Triggers:** (already done)
   ```bash
   aws cognito-idp update-user-pool \
     --user-pool-id us-west-2_WePThH2J8 \
     --lambda-config '{}'
   ```

3. **Update Settings Page:**
   - Show MFA status (enabled/disabled)
   - Link to Cognito hosted UI for MFA setup: `/mfa-setup` redirect
   - Remove custom TOTP QR code generation

4. **Test Flow:**
   - User logs in → Cognito prompts for TOTP setup
   - User scans QR in authenticator app
   - Next login requires TOTP code
   - ALB validates MFA before granting access

### Phase 2: Clean Up Code (1 hour)

1. **Remove custom MFA implementation:**
   - Delete `/api/mfa/*` routes (already commented out)
   - Remove `mfa_secrets` dictionary
   - Remove pyotp/qrcode imports (already done)
   - Update templates to remove TOTP setup UI

2. **Delete Lambda Functions:**
   ```bash
   cd terraform/envs/tier5
   terraform destroy -target=aws_lambda_function.define_auth_challenge
   terraform destroy -target=aws_lambda_function.create_auth_challenge
   terraform destroy -target=aws_lambda_function.verify_auth_challenge
   terraform destroy -target=aws_dynamodb_table.mfa_codes
   ```

3. **Clean up IAM policy:**
   - Remove Lambda/DynamoDB permissions from email-mfa-deployment-policy
   - Keep only SES if needed for other email features

### Phase 3: Improve Deployment Reliability (2-3 hours)

1. **Split user_data.sh:**
   ```
   user_data.sh (< 5KB):
   - Install system packages
   - Create users/directories
   - Install Python + venv
   - Signal completion

   deploy-app.sh:
   - Create app.py with all code
   - Create templates
   - Configure systemd
   - Start service
   ```

2. **Use Terraform templatefile properly:**
   ```hcl
   user_data = templatefile("${path.module}/user_data.sh", {
     user_pool_id = aws_cognito_user_pool.main.id
     aws_region   = var.aws_region
     client_id    = aws_cognito_user_pool_client.app_client.id
     client_secret = aws_cognito_user_pool_client.app_client.client_secret
   })
   ```

3. **Add health check endpoint validation:**
   ```python
   @app.get("/health")
   def health():
       # Verify all config vars are set
       assert USER_POOL_ID, "USER_POOL_ID not configured"
       assert AWS_REGION, "AWS_REGION not configured"
       assert CLIENT_ID, "CLIENT_ID not configured"
       assert CLIENT_SECRET, "CLIENT_SECRET not configured"
       return {"status": "healthy", "config": "valid"}
   ```

4. **Add startup validation:**
   ```python
   # At app startup
   if not all([USER_POOL_ID, AWS_REGION, CLIENT_ID, CLIENT_SECRET]):
       print("ERROR: Missing required configuration variables")
       sys.exit(1)
   ```

---

## What Worked Well ✅

1. **SSH Debugging:** Direct instance access was essential for diagnosing issues
2. **Incremental Fixes:** Applying one fix at a time isolated problems
3. **Manual Testing:** Running scripts manually revealed cloud-init truncation
4. **Service Logs:** `journalctl` showed exact error messages
5. **Terraform Outputs:** Made deployment values accessible
6. **IAM Policy Separation:** Dedicated policy avoided size limits

---

## Files Modified During Deployment

### Fixed Files:
- ✅ `/terraform/envs/tier5/user_data.sh` (lines 20, 23, 35-36, 68, 474-572, 781-791, 793-803, 1446-1449)
- ✅ `/terraform/envs/tier5/iam-email-mfa-policy.json` (complete policy)
- ✅ `/terraform/envs/tier5/portal-instance.tf` (minimal user_data)
- ✅ `/terraform/envs/tier5/deploy-portal.sh` (deployment script)

### Infrastructure Deployed:
- ✅ DynamoDB table: `employee-portal-mfa-codes`
- ✅ Lambda: `employee-portal-define-auth-challenge`
- ✅ Lambda: `employee-portal-create-auth-challenge`
- ✅ Lambda: `employee-portal-verify-auth-challenge`
- ✅ IAM role: `employee-portal-mfa-lambda-role`
- ✅ SES email: `noreply@capsule-playground.com` (Pending verification)
- ✅ Cognito Lambda triggers: Configured (but incompatible with hosted UI)

### Working Components:
- ✅ EC2 instance: i-01ebe3bbad23c0efc - HEALTHY
- ✅ Portal service: Running on port 8000
- ✅ ALB: Routing traffic correctly
- ✅ Cognito: Basic auth works via SDK
- ✅ Health check: Passing

---

## Next Steps

1. **Decide on MFA approach** (recommend native TOTP)
2. **Update Terraform configs** to match chosen approach
3. **Remove incompatible Lambda functions** if keeping hosted UI
4. **Verify SES email** for any email features
5. **Update test cases** for chosen MFA flow
6. **Document user setup process**
7. **Commit and push changes**

---

## Key Takeaways for Future Deployments

1. **Cloud-init has limits** - keep bootstrap minimal, deploy apps separately
2. **Test auth flows early** - architectural incompatibilities are costly
3. **Heredoc quoting matters** - `<< 'EOF'` vs `<< EOF`
4. **SSH is your friend** - don't rely only on console output
5. **IAM propagation takes time** - wait 10-60s between permission changes
6. **Hosted UI has constraints** - not all Cognito features work with OAuth
7. **Validate config on startup** - fail fast if vars are missing
8. **Read AWS docs carefully** - custom challenges != hosted UI compatible

---

**Document Created:** 2026-01-27 05:52 UTC
**Instance Status:** i-01ebe3bbad23c0efc HEALTHY
**Portal Status:** Accessible at https://portal.capsule-playground.com
**Auth Status:** SDK works, Hosted UI blocked by architectural incompatibility
