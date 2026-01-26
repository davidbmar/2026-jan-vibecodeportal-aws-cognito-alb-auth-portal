# SMS MFA Deployment - Next Steps

## Current Status

✅ **Deployment role created successfully:**
- Role: `employee-portal-deployer`
- ARN: `arn:aws:iam::821850226835:role/employee-portal-deployer`
- Permissions: Properly scoped PassRole for Cognito SMS

❌ **Cannot assume role from this server:**
- Current identity: `ssh-whitelist-role`
- Missing permission: `sts:AssumeRole` on the deployment role

## Deployment Options

### Option 1: Deploy from AWS Console (Recommended - Easiest)

**Steps:**
1. Open AWS Console → CloudShell (top right toolbar icon)
2. Run these commands:
```bash
# Clone/download the terraform code
cd /tmp
git clone <your-repo> || scp user@server:/home/ubuntu/cognito_alb_ec2 .

# Navigate to terraform directory
cd cognito_alb_ec2/terraform/envs/tier5

# Deploy
terraform init
terraform apply
```

**Why this works:** CloudShell uses your AWS Console credentials (likely admin or power user)

---

### Option 2: Add AssumeRole Permission to ssh-whitelist-role

**Steps:**
1. Go to IAM Console → Roles → `ssh-whitelist-role`
2. Add this inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-deployer"
    }
  ]
}
```

3. Then run from this server:
```bash
cd /home/ubuntu/cognito_alb_ec2
./deploy_with_role.sh
```

---

### Option 3: Use AWS CLI with Admin Credentials

**If you have AWS CLI configured locally with admin credentials:**

```bash
# On your local machine
cd /path/to/cognito_alb_ec2/terraform/envs/tier5
terraform apply
```

---

### Option 4: Manual Cognito Update (Quick Fix)

**If you just want SMS MFA working NOW without terraform:**

1. Go to AWS Console → Cognito → User Pools → `us-east-1_kF4pcrUVF`
2. Sign-in experience → Multi-factor authentication
3. Change MFA enforcement: `Required` → `Optional`
4. Enable SMS MFA:
   - SNS role ARN: `arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role`
   - External ID: `employee-portal-external`
5. Save changes

**Note:** This works but terraform will show drift. Re-run terraform later to sync.

---

## What Each Option Requires

| Option | Requires | Time | Recommended |
|--------|----------|------|-------------|
| **Option 1: CloudShell** | AWS Console access | 2 min | ✅ Yes |
| **Option 2: Update ssh-whitelist-role** | IAM admin | 5 min | ✅ Yes |
| **Option 3: Local CLI** | AWS CLI setup | 2 min | ⚠️ If configured |
| **Option 4: Manual Console** | AWS Console access | 1 min | ⚠️ Quick fix only |

---

## After Deployment

Once SMS MFA is enabled in Cognito, you can deploy the Settings UI page:

```bash
# On portal instance (i-09076e5809793e2eb)
bash /tmp/deploy_settings_page.sh
```

This will give users the configuration page to choose between TOTP and SMS MFA.

---

## Why This Happened

The `employee-portal-deployer` role has proper permissions to deploy, but we need a way to **assume** that role. Think of it like:

- ✅ We created a powerful key (deployment role)
- ❌ But we don't have permission to pick up the key (assume the role)

The trust policy allows `arn:aws:iam::821850226835:root` to assume it, which means **any principal in the account can assume it if they have `sts:AssumeRole` permission**. The `ssh-whitelist-role` just needs that permission added.

---

## Security Note

This design is intentional and secure:
- Not every role should be able to assume deployment roles
- Requires explicit permission (prevents accidental escalation)
- Following AWS best practices

The deployment role itself has properly scoped permissions (narrow PassRole, specific resources, explicit denies).
