# Quick IAM Setup for Email MFA

## Policy Size Check

```bash
# Check the policy size
wc -c iam-email-mfa-policy.json
# Should show < 6144 bytes
```

Current policy: **~2,100 bytes** ✅ Well under the 6,144 limit!

---

## Option 1: Automated Script (Recommended)

**One command does everything:**

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
./deploy-email-mfa-with-permissions.sh
```

This script will:
1. ✅ Create the new IAM policy
2. ✅ Attach it to `ssh-whitelist-role`
3. ✅ Deploy infrastructure with Terraform
4. ✅ Verify everything was created
5. ✅ Show next steps

---

## Option 2: Manual Commands

If you prefer to run commands manually:

### Step 1: Create the Policy

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

aws iam create-policy \
  --policy-name email-mfa-deployment-policy \
  --policy-document file://iam-email-mfa-policy.json \
  --description "Permissions for email MFA infrastructure (DynamoDB, SES, Lambda)" \
  --region us-west-2
```

Expected output:
```json
{
    "Policy": {
        "PolicyName": "email-mfa-deployment-policy",
        "PolicyId": "...",
        "Arn": "arn:aws:iam::821850226835:policy/email-mfa-deployment-policy",
        "CreateDate": "..."
    }
}
```

### Step 2: Attach Policy to Role

```bash
aws iam attach-role-policy \
  --role-name ssh-whitelist-role \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy
```

Expected: No output (success)

### Step 3: Verify Attachment

```bash
aws iam list-attached-role-policies --role-name ssh-whitelist-role
```

Should show both policies:
- `ssh-whitelist-policy`
- `email-mfa-deployment-policy`

### Step 4: Wait for IAM Propagation

```bash
# IAM changes take a few seconds to propagate
sleep 10
```

### Step 5: Deploy Infrastructure

```bash
terraform init -upgrade
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

---

## What the New Policy Provides

The `email-mfa-deployment-policy` adds these permissions:

| Service | Permissions | Resources |
|---------|-------------|-----------|
| **DynamoDB** | CreateTable, DescribeTable, UpdateTable, DeleteTable, PutItem, GetItem, DeleteItem | `employee-portal-mfa-codes` table |
| **SES** | VerifyEmailIdentity, SendEmail, GetIdentityVerificationAttributes | All (required for SES) |
| **Lambda** | CreateFunction, UpdateFunction, GetFunction, DeleteFunction, AddPermission | `employee-portal-*auth-challenge` functions |
| **IAM** | CreateRole, PutRolePolicy, PassRole (for Lambda) | `employee-portal-mfa-lambda-role` |
| **CloudWatch Logs** | CreateLogGroup, DeleteLogGroup | Lambda log groups |

**Total size:** ~2,100 bytes (65% under limit)

---

## Verify Policy Attachment

```bash
# List all policies attached to the role
aws iam list-attached-role-policies --role-name ssh-whitelist-role

# Get details of the new policy
aws iam get-policy \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy

# Get policy document
aws iam get-policy-version \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy \
  --version-id v1 \
  --query 'PolicyVersion.Document'
```

---

## Troubleshooting

### Error: Policy already exists

If you see "EntityAlreadyExists", the policy was created in a previous attempt:

```bash
# Just attach it
aws iam attach-role-policy \
  --role-name ssh-whitelist-role \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy
```

### Error: Policy is already attached

Good! That means it's ready. Proceed to Terraform.

### Error: Policy exceeds size limit

Check policy size:
```bash
wc -c iam-email-mfa-policy.json
```

Our policy is only ~2,100 bytes, well under the 6,144 limit.

### Error: Cannot exceed quota for PoliciesPerRole

You can have up to 10 managed policies per role. Check current count:
```bash
aws iam list-attached-role-policies --role-name ssh-whitelist-role | grep -c PolicyName
```

---

## Clean Up (if needed)

To remove the policy later:

```bash
# Detach from role
aws iam detach-role-policy \
  --role-name ssh-whitelist-role \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy

# Delete policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::821850226835:policy/email-mfa-deployment-policy
```

---

## After Deployment

Once infrastructure is deployed, run tests:

```bash
cd /home/ubuntu/cognito_alb_ec2
./tests/run-email-mfa-tests.sh all
```

This will:
- Run unit tests (Lambda functions)
- Run integration tests (AWS services)
- Run E2E tests (user flows)
- Generate test reports
- Show next steps
