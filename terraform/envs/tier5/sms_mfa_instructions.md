# Adding SMS MFA to Employee Portal

## Overview

This guide shows how to add SMS (text message) MFA as an option alongside TOTP (authenticator app) MFA.

## What Changes

**Current Setup:**
- MFA is required (forced on)
- Only TOTP (authenticator apps like Google Authenticator)

**New Setup:**
- MFA is optional (users can choose their method)
- TOTP (authenticator app) - FREE
- SMS (text message) - ~$0.00645 per SMS in US

## Cost Implications

### SMS Pricing (via Amazon SNS)
- **US & Canada**: ~$0.0065 per SMS
- **Europe**: ~$0.01-0.02 per SMS
- **Other regions**: Varies (can be higher)

### Monthly Estimate
If you have 5 users receiving:
- 2 SMS per day (login + verification) = 60 SMS/month per user
- 5 users × 60 = 300 SMS/month
- Cost: 300 × $0.0065 = **~$2/month**

TOTP is free, so offering both options is recommended.

## Security Considerations

### TOTP (Authenticator App) ✅ More Secure
- Not vulnerable to SIM swapping
- Works offline
- No SMS interception risk
- Industry best practice

### SMS ⚠️ Less Secure (but more convenient)
- Vulnerable to SIM swapping attacks
- SMS can be intercepted
- Relies on carrier infrastructure
- Better than no MFA, but not ideal

**Recommendation**: Offer both, but encourage users to use TOTP.

## Implementation Steps

### Step 1: Update main.tf

Edit `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/main.tf`:

**Find this section (lines 194-198):**
```hcl
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }
```

**Replace with:**
```hcl
  mfa_configuration = "OPTIONAL"  # Changed from "ON" to "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  # NEW: SMS MFA Configuration
  sms_configuration {
    external_id    = "${var.project_name}-external"
    sns_caller_arn = aws_iam_role.cognito_sms_role.arn
  }

  # NEW: Enable SMS MFA
  sms_authentication_message = "Your Employee Portal authentication code is {####}"
```

**Then find the schema block (around line 207) and add phone_number:**
```hcl
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # NEW: Add phone number schema for SMS MFA
  schema {
    name                = "phone_number"
    attribute_data_type = "String"
    required            = false  # Not required, only if they want SMS MFA
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }
```

### Step 2: Apply Terraform Changes

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Validate configuration
terraform validate

# See what will change
terraform plan

# Apply changes
terraform apply
```

### Step 3: How Users Enable SMS MFA

After deployment, users can set up SMS MFA:

**Option A: Via AWS Console**
1. Go to Cognito User Pool
2. Select user
3. Add phone number attribute
4. User can then choose SMS MFA on next login

**Option B: Via Cognito Hosted UI**
1. User logs in
2. Goes to MFA settings
3. Can add phone number and enable SMS MFA

**Option C: Programmatically (Admin)**
```bash
# Add phone number to user
aws cognito-idp admin-update-user-attributes \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username user@example.com \
  --user-attributes Name=phone_number,Value="+12025551234" \
  --region us-east-1

# Set user's preferred MFA to SMS
aws cognito-idp admin-set-user-mfa-preference \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username user@example.com \
  --sms-mfa-settings '{"Enabled":true,"PreferredMfa":true}' \
  --region us-east-1
```

## What Users Will See

### With OPTIONAL MFA

**During First Login:**
- User logs in with email/password
- Prompted to set up MFA (can choose TOTP or SMS)
- Can skip if they prefer (not recommended)

**If They Choose TOTP:**
- Scan QR code with authenticator app
- Enter 6-digit code
- Free forever

**If They Choose SMS:**
- Enter phone number (format: +12025551234)
- Receive verification code via SMS
- Enter code to complete setup
- Costs apply per SMS

### Making MFA Required Again

If you want to force MFA (but let users choose between TOTP/SMS):

Change `mfa_configuration = "OPTIONAL"` to `mfa_configuration = "ON"`

This requires users to set up one method but lets them choose which.

## Testing

After deployment:

1. **Create test user** with phone number:
```bash
aws cognito-idp admin-create-user \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username testuser@example.com \
  --user-attributes \
    Name=email,Value=testuser@example.com \
    Name=email_verified,Value=true \
    Name=phone_number,Value="+12025551234" \
    Name=phone_number_verified,Value=true \
  --temporary-password "TempPass123!" \
  --region us-east-1
```

2. **Enable SMS MFA for test user**:
```bash
aws cognito-idp admin-set-user-mfa-preference \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username testuser@example.com \
  --sms-mfa-settings '{"Enabled":true,"PreferredMfa":true}' \
  --region us-east-1
```

3. **Test login**: User should receive SMS code

## Monitoring SMS Costs

### Set SNS Spending Limit
```bash
# Set monthly SMS spending limit (e.g., $10)
aws sns set-sms-attributes \
  --attributes MonthlySpendLimit=10 \
  --region us-east-1
```

### View SMS Usage
```bash
# Check current month SMS spending
aws sns get-sms-attributes \
  --attributes MonthlySpendLimit \
  --region us-east-1
```

### CloudWatch Metrics
Monitor in AWS Console:
- CloudWatch → SNS → SMS Success Rate
- CloudWatch → SNS → SMS Spend

## Rollback

If you need to remove SMS MFA:

1. Remove the `sms_configuration` block from main.tf
2. Remove the phone_number schema
3. Change `mfa_configuration` back to "ON" (TOTP only)
4. Run `terraform apply`

## Summary

| Feature | TOTP | SMS |
|---------|------|-----|
| Cost | Free | ~$0.0065 per SMS |
| Security | High | Medium |
| Convenience | Medium | High |
| Offline | Yes | No |
| SIM Swap Risk | No | Yes |
| Setup | Scan QR | Enter phone |

**Recommendation**:
- Enable both options (done with these changes)
- Set MFA to OPTIONAL initially so users can choose
- Encourage TOTP for security-conscious users
- Offer SMS for users who prefer convenience

## Files Created

- `sms_mfa_additions.tf` - IAM role for SMS sending
- `sms_mfa_instructions.md` - This file

## Questions?

- SMS not working? Check phone number format: +[country code][number]
- Costs too high? Disable SMS, keep TOTP only
- Want to force MFA? Set `mfa_configuration = "ON"`

---

**Next Steps**: Edit main.tf with the changes above, then run `terraform apply`
