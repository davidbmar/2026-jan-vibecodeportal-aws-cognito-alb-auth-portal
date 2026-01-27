# Email MFA Deployment - Permissions Issue

## Issue Summary

**Date:** 2026-01-27
**Status:** ⚠️ Infrastructure deployment blocked by IAM permissions

### What Happened

Terraform attempted to deploy the email MFA infrastructure but failed due to insufficient IAM permissions on the current role (`ssh-whitelist-role`).

### Failed Operations

1. **DynamoDB Table Creation**
   ```
   Error: User is not authorized to perform: dynamodb:CreateTable
   Resource: arn:aws:dynamodb:us-west-2:821850226835:table/employee-portal-mfa-codes
   ```

2. **SES Email Identity Creation**
   ```
   Error: User is not authorized to perform: ses:VerifyEmailIdentity
   Resource: noreply@capsule-playground.com
   ```

3. **Lambda Function Operations**
   - Unable to check if Lambda functions were created
   - Missing `lambda:ListFunctions` permission

### What Was Successfully Prepared

✅ **Terraform Files Created:**
- `terraform/envs/tier5/dynamodb.tf` - DynamoDB table config
- `terraform/envs/tier5/lambda.tf` - Lambda functions and IAM roles
- `terraform/envs/tier5/ses.tf` - SES email identity
- `terraform/envs/tier5/main.tf` - Updated Cognito configuration
- `terraform/envs/tier5/variables.tf` - Updated variables

✅ **Lambda Function Code:**
- `lambdas/define_auth_challenge.py`
- `lambdas/create_auth_challenge.py`
- `lambdas/verify_auth_challenge.py`

✅ **Terraform Validation:**
- All files validated successfully
- Plan generated successfully
- No syntax errors

❌ **Not Yet Created:**
- DynamoDB table: `employee-portal-mfa-codes`
- Lambda functions (3 total)
- Lambda IAM role and policies
- SES email identity
- Cognito Lambda triggers

---

## Solutions

### Option 1: Add Required Permissions (Recommended)

Add the following permissions to the `ssh-whitelist-role` IAM role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DescribeTable",
        "dynamodb:UpdateTable",
        "dynamodb:DeleteTable",
        "dynamodb:TagResource"
      ],
      "Resource": "arn:aws:dynamodb:us-west-2:821850226835:table/employee-portal-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ses:VerifyEmailIdentity",
        "ses:GetIdentityVerificationAttributes",
        "ses:DeleteIdentity"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:GetFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:ListFunctions",
        "lambda:TagResource",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:GetPolicy"
      ],
      "Resource": "arn:aws:lambda:us-west-2:821850226835:function:employee-portal-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-mfa-lambda-role"
    }
  ]
}
```

**Steps:**
1. Go to AWS Console → IAM → Roles
2. Find `ssh-whitelist-role`
3. Add inline policy with above permissions
4. Return to terminal and run: `terraform apply tfplan`

---

### Option 2: Use AWS CloudShell (Alternative)

If you have AWS Console access, use CloudShell with admin permissions:

```bash
# 1. Open AWS CloudShell (from AWS Console)
# 2. Clone repo
git clone <your-repo-url>
cd cognito_alb_ec2/terraform/envs/tier5

# 3. Deploy
terraform init
terraform apply
```

CloudShell runs with your IAM user permissions, which likely have the required access.

---

### Option 3: Use Different IAM Role

If you have another IAM role with broader permissions:

```bash
# Assume the role
aws sts assume-role \
  --role-arn arn:aws:iam::821850226835:role/YOUR_ADMIN_ROLE \
  --role-session-name email-mfa-deployment

# Export credentials
export AWS_ACCESS_KEY_ID=<from-output>
export AWS_SECRET_ACCESS_KEY=<from-output>
export AWS_SESSION_TOKEN=<from-output>

# Deploy
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
terraform apply
```

---

### Option 4: Manual Creation (Last Resort)

If IAM permissions can't be modified, create resources manually:

#### 4.1 Create DynamoDB Table

```bash
aws dynamodb create-table \
  --table-name employee-portal-mfa-codes \
  --attribute-definitions AttributeName=username,AttributeType=S \
  --key-schema AttributeName=username,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=Name,Value=employee-portal-mfa-codes Key=Environment,Value=tier5 \
  --region us-west-2

# Enable TTL
aws dynamodb update-time-to-live \
  --table-name employee-portal-mfa-codes \
  --time-to-live-specification "Enabled=true, AttributeName=ttl" \
  --region us-west-2
```

#### 4.2 Create SES Email Identity

```bash
aws ses verify-email-identity \
  --email-address noreply@capsule-playground.com \
  --region us-west-2
```

Then check email inbox for verification email and click the link.

#### 4.3 Create Lambda Functions

Use AWS Console → Lambda → Create Function:

1. **DefineAuthChallenge**
   - Name: `employee-portal-define-auth-challenge`
   - Runtime: Python 3.11
   - Upload: `lambdas/define_auth_challenge.py`

2. **CreateAuthChallenge**
   - Name: `employee-portal-create-auth-challenge`
   - Runtime: Python 3.11
   - Upload: `lambdas/create_auth_challenge.py`
   - Environment variables:
     - `MFA_CODES_TABLE`: `employee-portal-mfa-codes`
     - `SES_FROM_EMAIL`: `noreply@capsule-playground.com`

3. **VerifyAuthChallenge**
   - Name: `employee-portal-verify-auth-challenge`
   - Runtime: Python 3.11
   - Upload: `lambdas/verify_auth_challenge.py`
   - Environment variables:
     - `MFA_CODES_TABLE`: `employee-portal-mfa-codes`

#### 4.4 Configure Cognito

1. Go to Cognito User Pool → `employee-portal-user-pool`
2. Click "User pool properties" → "Lambda triggers"
3. Add triggers:
   - Define auth challenge: `employee-portal-define-auth-challenge`
   - Create auth challenge: `employee-portal-create-auth-challenge`
   - Verify auth challenge response: `employee-portal-verify-auth-challenge`
4. Update MFA settings → Set to "OFF"
5. Update app client → Add explicit auth flows:
   - `ALLOW_CUSTOM_AUTH`
   - `ALLOW_USER_SRP_AUTH`
   - `ALLOW_REFRESH_TOKEN_AUTH`

---

## Required Permissions Summary

For full automation, the IAM role needs:

| Service | Permissions | Why Needed |
|---------|-------------|------------|
| DynamoDB | CreateTable, DescribeTable, UpdateTable | MFA code storage |
| SES | VerifyEmailIdentity, GetIdentityVerificationAttributes | Send MFA emails |
| Lambda | CreateFunction, UpdateFunction, GetFunction, AddPermission | MFA auth logic |
| IAM | CreateRole, PutRolePolicy, PassRole | Lambda execution role |
| Cognito-IDP | UpdateUserPool (already has) | Configure Lambda triggers |

---

## Next Steps

### Immediate

1. **Choose a solution from above** (Option 1 recommended)
2. **Retry deployment:**
   ```bash
   cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
   terraform apply
   ```

### After Successful Deployment

1. **Verify SES Email:**
   ```bash
   aws ses get-identity-verification-attributes \
     --identities noreply@capsule-playground.com \
     --region us-west-2
   ```
   Check inbox and click verification link if needed.

2. **Run Tests:**
   ```bash
   cd /home/ubuntu/cognito_alb_ec2
   ./tests/run-email-mfa-tests.sh all
   ```

3. **Manual Verification:**
   - Test login flow at https://portal.capsule-playground.com
   - Check Lambda CloudWatch logs
   - Verify email delivery
   - Check DynamoDB for codes

---

## Current State

```
Infrastructure Preparation: ✅ COMPLETE
  - Terraform files: ✅ Created
  - Lambda code: ✅ Written
  - Configuration: ✅ Updated
  - Validation: ✅ Passed

Infrastructure Deployment: ⚠️ BLOCKED
  - IAM permissions: ❌ Insufficient
  - DynamoDB table: ❌ Not created
  - Lambda functions: ❌ Not created
  - SES email: ❌ Not verified
  - Cognito triggers: ❌ Not configured

Test Suite: ✅ READY
  - Unit tests: ✅ Written
  - Integration tests: ✅ Written
  - E2E tests: ✅ Written
  - Test runner: ✅ Created
```

---

## Contact / Support

If you encounter issues with any of the solutions:

1. Check AWS CloudTrail for detailed error messages
2. Review IAM role policies in AWS Console
3. Consult AWS documentation for service-specific requirements
4. Consider reaching out to AWS Support for IAM permission guidance

---

**Last Updated:** 2026-01-27
**Status:** Awaiting IAM permissions update
**Blocker:** `dynamodb:CreateTable`, `ses:VerifyEmailIdentity`, `lambda:CreateFunction`
