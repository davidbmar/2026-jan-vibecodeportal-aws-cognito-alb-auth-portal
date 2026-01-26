# Quick Guide: Enable SMS MFA

## TL;DR

✅ **Yes, SMS MFA is natively supported by AWS Cognito** - no third-party services needed!

## What You Get

- **Current**: TOTP only (authenticator apps)
- **After**: TOTP + SMS (user's choice)
- **Cost**: ~$0.0065 per SMS in US (TOTP remains free)

## Quick Decision Matrix

| Choose SMS MFA if... | Skip SMS MFA if... |
|---------------------|-------------------|
| Users want convenience | Security is top priority |
| You're okay with ~$2-5/month | You want to minimize costs |
| Users lose their phones often | You're worried about SIM swapping |
| Easier user onboarding | Users are tech-savvy (can use TOTP) |

## 3-Step Implementation

### Step 1: Copy the IAM role file

The file `sms_mfa_additions.tf` has already been created - it's ready to use!

Location: `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/sms_mfa_additions.tf`

### Step 2: Edit main.tf

Open `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/main.tf` and make these changes:

**Change 1: Update MFA configuration (around line 194)**

```diff
  # Cognito User Pool
  resource "aws_cognito_user_pool" "main" {
    name = "${var.project_name}-user-pool"

    username_attributes      = ["email"]
    auto_verified_attributes = ["email"]

    password_policy {
      minimum_length                   = 8
      require_lowercase                = true
      require_numbers                  = true
      require_symbols                  = true
      require_uppercase                = true
      temporary_password_validity_days = 7
    }

-   mfa_configuration = "ON"
+   mfa_configuration = "OPTIONAL"  # Users can choose TOTP or SMS

    software_token_mfa_configuration {
      enabled = true
    }

+   # SMS MFA Configuration
+   sms_configuration {
+     external_id    = "${var.project_name}-external"
+     sns_caller_arn = aws_iam_role.cognito_sms_role.arn
+   }
+
+   sms_authentication_message = "Your Employee Portal authentication code is {####}"

    account_recovery_setting {
      recovery_mechanism {
        name     = "verified_email"
        priority = 1
      }
    }
```

**Change 2: Add phone_number schema (after the email schema, around line 217)**

```diff
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

+   schema {
+     name                = "phone_number"
+     attribute_data_type = "String"
+     required            = false
+     mutable             = true
+
+     string_attribute_constraints {
+       min_length = 1
+       max_length = 2048
+     }
+   }

    tags = {
      Name = "${var.project_name}-user-pool"
    }
  }
```

### Step 3: Deploy

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Validate
terraform validate

# Preview changes
terraform plan

# Apply
terraform apply
```

Terraform will:
1. Create IAM role for SMS sending
2. Update Cognito User Pool to support SMS MFA
3. Keep existing TOTP support

## After Deployment

### How Users Choose Their MFA Method

**Option 1: Admin sets it up (Recommended for first rollout)**

```bash
# Add phone number to user
aws cognito-idp admin-update-user-attributes \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username dmar@capsule.com \
  --user-attributes Name=phone_number,Value="+12025551234" \
  --region us-east-1

# Set SMS as preferred MFA
aws cognito-idp admin-set-user-mfa-preference \
  --user-pool-id us-east-1_kF4pcrUVF \
  --username dmar@capsule.com \
  --sms-mfa-settings '{"Enabled":true,"PreferredMfa":true}' \
  --region us-east-1
```

**Option 2: Users choose during login**
- With `mfa_configuration = "OPTIONAL"`, users pick their method at first login
- They can change it later in account settings

### Cost Monitoring

Set a spending limit:
```bash
aws sns set-sms-attributes \
  --attributes MonthlySpendLimit=10 \
  --region us-east-1
```

## Security Note

📱 **TOTP (Authenticator App)** = More secure ✅
- Not vulnerable to SIM swapping
- Works offline
- Industry best practice

📨 **SMS** = Less secure but convenient ⚠️
- Vulnerable to SIM swapping attacks
- Relies on carrier
- Better than no MFA!

**Best Practice**: Offer both, but encourage TOTP for sensitive accounts.

## Make MFA Required (Force Users to Pick One)

If you want to require MFA but let users choose the method:

Change line 194 in main.tf:
```hcl
mfa_configuration = "ON"  # Force MFA, but user chooses TOTP or SMS
```

With "ON":
- Users MUST set up MFA
- They can choose TOTP or SMS
- Can't skip MFA

With "OPTIONAL" (current):
- Users CAN set up MFA
- They choose TOTP, SMS, or skip
- More flexible

## Rollback

If you don't like SMS MFA, just:

1. Delete `sms_mfa_additions.tf`
2. Remove the SMS configuration from main.tf
3. Change `mfa_configuration` back to "ON"
4. Run `terraform apply`

## Questions?

**Q: Does this disable TOTP?**
A: No! Both methods work. Users choose their preference.

**Q: How much will this cost?**
A: ~$0.0065 per SMS. For 5 users logging in twice daily = ~$2/month.

**Q: Is SMS secure enough?**
A: It's better than no MFA, but TOTP is more secure. Offer both!

**Q: Can I make it required?**
A: Yes! Change `mfa_configuration = "OPTIONAL"` to `"ON"`

**Q: What if user enters wrong phone format?**
A: Must be E.164 format: +[country code][number] (e.g., +12025551234)

## Summary

✅ SMS MFA is **native to Cognito** (uses Amazon SNS)
✅ No third-party services needed
✅ Small cost (~$2-5/month for typical usage)
✅ Easy to implement (2 file changes)
✅ Gives users choice between TOTP and SMS
✅ Can be reversed anytime

**Files you need**:
- ✅ `sms_mfa_additions.tf` (already created)
- ✏️ `main.tf` (edit as shown above)

Then run: `terraform apply`

---

**Full instructions**: See `sms_mfa_instructions.md` for detailed information
