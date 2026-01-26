# SMS MFA & Settings Page Deployment Status

## Quick Summary

### ✅ Completed
1. **SMS MFA Terraform Configuration** - Created IAM role, updated Cognito config
2. **Settings UI Page** - Full MFA & password management page created
3. **Documentation** - TOTP vs SMS security comparison

### ⚠️ Partial - Needs Admin Action
**SMS MFA Cognito Update** - Blocked by IAM permissions (needs `iam:PassRole`)

### 📋 Ready to Deploy
**Settings Page** - Ready to deploy to portal with one script

---

## Part 1: SMS MFA Infrastructure (Terraform)

### What Was Done

#### Files Created:
- ✅ `sms_mfa_additions.tf` - IAM role for Cognito SMS sending
- ✅ `main.tf` - Updated with SMS configuration
- ✅ Documentation (3 guide files)

#### Changes Applied:
- ✅ IAM Role created: `employee-portal-cognito-sms-role`
- ✅ IAM Policy attached: SNS Publish permission
- ❌ Cognito User Pool update: **BLOCKED** (see below)

### What's Blocking SMS MFA

**Error Message:**
```
AccessDeniedException: User arn:aws:sts::821850226835:assumed-role/ssh-whitelist-role/...
is not authorized to perform: iam:PassRole on resource:
arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role
```

### About PassRole Security (Important!)

**PassRole is NOT a security vulnerability** - it's a security FEATURE! ✅

#### Why PassRole Exists:
PassRole prevents **privilege escalation attacks**:

**Without PassRole:**
```
1. Attacker creates powerful IAM role with admin permissions
2. Attacker passes that role to a service (like Cognito)
3. Service now has more permissions than attacker
4. Attacker abuses service to escalate privileges
```

**With PassRole (current AWS design):**
```
1. Attacker tries to pass a role to a service
2. AWS checks: "Does this user have iam:PassRole permission?"
3. If no → DENIED (what happened to us)
4. If yes → Check if scoped properly (specific role + specific service)
```

#### The Secure Solution

Add a **scoped PassRole permission** (not wide open):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cognito-idp.amazonaws.com"
        }
      }
    }
  ]
}
```

**Why this is secure:**
- ✅ Only this specific role (not any role)
- ✅ Only to Cognito service (not any service)
- ✅ Can't be abused for privilege escalation
- ✅ Follows AWS security best practices

### How to Complete SMS MFA Deployment

**Option 1: Apply from AWS Console (Recommended)**
```bash
# Login to AWS Console with admin/full permissions
# Go to CloudShell or use AWS CLI locally
cd /path/to/terraform
terraform apply
```

**Option 2: Add PassRole to ssh-whitelist-role**

If you have permission to modify `ssh-whitelist-role`:

1. Go to IAM Console → Roles → ssh-whitelist-role
2. Add inline policy with the JSON above
3. Run `terraform apply` again from this server

**Option 3: Use a Different IAM Role**

Run terraform from an EC2 instance or IAM user with proper permissions.

---

## Part 2: Settings UI Page

### What Was Created

#### Files:
- ✅ `/home/ubuntu/cognito_alb_ec2/app/templates/settings.html` - Full settings page
- ✅ `/home/ubuntu/cognito_alb_ec2/app/settings_route.py` - Python route code
- ✅ `/home/ubuntu/deploy_settings_page.sh` - Deployment script

#### Features of Settings Page:

**MFA Configuration Section:**
- ✅ TOTP (Authenticator App) option
  - **Explains what TOTP stands for** (Time-based One-Time Password)
  - Lists security benefits (SIM swap protection, offline, free)
  - Marked as RECOMMENDED
  - Link to MFA setup page

- ✅ SMS (Text Message) option
  - Security warnings (less secure, SIM swapping risk)
  - Explains convenience trade-offs
  - Contact admin to enable note

**Password Management:**
- ✅ Password requirements displayed
- ✅ Link to password reset flow
- ✅ Clear instructions

**Account Information:**
- ✅ Shows user email
- ✅ Displays user groups with badges
- ✅ Admin badge highlighted in red

**Security Best Practices:**
- ✅ Educational tips for users
- ✅ Backup codes reminder
- ✅ Never share credentials

### TOTP vs SMS Comparison (as shown in UI)

| Feature | TOTP (Recommended) | SMS |
|---------|-------------------|-----|
| **Security** | ✅ Most Secure | ⚠️ Less Secure |
| **SIM Swap Protection** | ✅ Protected | ❌ Vulnerable |
| **Works Offline** | ✅ Yes | ❌ No |
| **Cost** | ✅ Free | ⚠️ ~$0.0065/SMS |
| **Setup** | App + QR Code | Phone number |
| **Industry Standard** | ✅ Banks, Gov | ⚠️ Legacy |

### How to Deploy Settings Page

**Super Easy - One Command:**

```bash
# Connect to portal instance via Session Manager or SSH
# Then run:

bash /tmp/deploy_settings_page.sh
```

Or copy the script from `/home/ubuntu/deploy_settings_page.sh` and paste it.

The script will:
1. ✅ Backup app.py
2. ✅ Create settings.html template
3. ✅ Add /settings route to app.py
4. ✅ Update navigation to add "Settings" link
5. ✅ Restart service
6. ✅ Verify deployment

**After deployment, users will see:**
- New "Settings" link in navigation (between Admin Panel and Logout)
- Full settings page at `/settings` with MFA and password options

---

## Part 3: Complete Deployment Plan

### Recommended Order:

#### Step 1: Deploy Settings Page (No Blockers)
```bash
# On portal instance (i-09076e5809793e2eb):
bash /tmp/deploy_settings_page.sh
```
**Time:** 30 seconds
**Risk:** Low (has rollback in script)

#### Step 2: Complete SMS MFA (Needs Admin)
```bash
# From AWS Console or admin terminal:
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
terraform apply
```
**Time:** 2 minutes
**Risk:** Low (only updates Cognito config)

### What Users Will See

**Before any deployment:**
- Current portal (no settings page, TOTP MFA only)

**After Settings Page deployment:**
- New Settings page
- MFA options explained (TOTP recommended, SMS available soon)
- Password change link
- **SMS won't work yet** (Cognito not updated)

**After SMS MFA terraform apply:**
- Settings page active
- Users can choose TOTP or SMS
- SMS codes work via Amazon SNS

---

## Security Notes

### TOTP vs SMS - Which to Use?

**Recommend to users:**
1. **High-security accounts (admins):** TOTP only
2. **Standard users:** TOTP preferred, SMS acceptable
3. **Non-tech users:** SMS okay (better than no MFA)

**TOTP Advantages:**
- Not vulnerable to SIM swapping attacks
- Works offline (airplane mode, no signal)
- Industry best practice (used by Google, AWS, banks)
- Free (no per-use cost)
- Codes generated locally on device

**SMS Disadvantages:**
- Vulnerable to SIM swapping (attacker convinces carrier to transfer number)
- SMS interception possible
- Requires cell service
- Small cost per message
- Less privacy (carrier sees messages)

**Bottom Line:**
SMS MFA is **much better than no MFA**, but TOTP is the gold standard.

### PassRole is NOT Insecure

**Common Misconception:** "PassRole is a security hole"
**Reality:** PassRole is a security control that prevents privilege escalation

**Good security practices:**
- ✅ Scope PassRole to specific roles
- ✅ Scope PassRole to specific services
- ✅ Use Conditions to restrict usage
- ✅ Audit PassRole usage with CloudTrail

**Bad practices (we're NOT doing this):**
- ❌ `"Resource": "*"` (pass any role)
- ❌ No service condition (pass to any service)
- ❌ Wide-open permissions

Our PassRole permission is properly scoped and secure.

---

## Files Reference

### Terraform (SMS MFA):
- `sms_mfa_additions.tf` - IAM role (already applied)
- `main.tf` - Updated Cognito config (needs admin to apply)
- `ENABLE_SMS_MFA.md` - Quick guide
- `sms_mfa_instructions.md` - Detailed guide
- `SMS_MFA_CHANGES.txt` - Exact changes made

### UI (Settings Page):
- `app/templates/settings.html` - Full page template
- `app/settings_route.py` - Python route code
- `deploy_settings_page.sh` - Deployment script

### This Document:
- `SMS_MFA_AND_SETTINGS_STATUS.md` - Complete status report

---

## Next Steps

### Immediate (Can do now):
1. Deploy Settings page to portal (no blockers)
2. Users can see MFA options and education

### Soon (Needs admin):
1. Run terraform apply from admin account
2. SMS MFA becomes functional
3. Users can choose their MFA method

### Future Enhancements:
1. Add phone number management UI
2. Show current MFA method on settings page
3. Add MFA status indicators
4. Backup codes display/download

---

## Cost Summary

**Current monthly cost:** ~$25-30
- EC2: $7.50
- ALB: $16.20
- Cognito: Free

**After SMS MFA enabled:**
- Add ~$2-5 for SMS messages (if users choose SMS)
- TOTP remains free

**Example:** 5 users, all choose SMS, 2 logins/day:
- 5 users × 60 SMS/month = 300 SMS
- 300 × $0.0065 = $1.95/month

**Most users choose TOTP** (free + more secure), so actual cost increase: ~$0.50-2/month

---

## Questions?

**Q: Is PassRole a security risk?**
A: No! It's a security feature that prevents privilege escalation. We're using it correctly.

**Q: Should I offer SMS MFA?**
A: Yes! Many users find it convenient. TOTP is more secure, but SMS > no MFA.

**Q: Can I make MFA required?**
A: Yes! Change `mfa_configuration = "ON"` in main.tf. Users must pick TOTP or SMS.

**Q: What if SMS costs too much?**
A: Most users choose TOTP (free). Set SNS spending limits. Encourage TOTP.

**Q: Is TOTP really more secure?**
A: YES! Not vulnerable to SIM swapping, which is a real attack vector. Banks use TOTP.

---

**Status as of:** 2026-01-25
**SMS MFA:** Infrastructure ready, needs admin terraform apply
**Settings Page:** Ready to deploy, one command
**Security:** PassRole properly scoped, TOTP recommended over SMS
