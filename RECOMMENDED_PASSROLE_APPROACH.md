# Recommended Approach: Secure PassRole for Cognito SMS

## TL;DR

**PassRole is NOT insecure** - it's a security feature. The key is **how narrowly you scope it**.

## Recommended Solution: Minimal Deployment Role

Create a dedicated role just for infrastructure deployments with the narrowest possible PassRole permission.

### Step 1: Create Deployment Role

```bash
# Create the role
aws iam create-role \
  --role-name employee-portal-deployer \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::821850226835:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "employee-portal-deploy"
        }
      }
    }]
  }'
```

### Step 2: Attach Minimal Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CognitoDeployment",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:UpdateUserPool",
        "cognito-idp:DescribeUserPool"
      ],
      "Resource": "arn:aws:cognito-idp:us-east-1:821850226835:userpool/us-east-1_kF4pcrUVF"
    },
    {
      "Sid": "IAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies"
      ],
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role"
    },
    {
      "Sid": "ScopedPassRoleForCognitoOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cognito-idp.amazonaws.com"
        }
      }
    },
    {
      "Sid": "DenyPassRoleToOtherServices",
      "Effect": "Deny",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::821850226835:role/employee-portal-cognito-sms-role",
      "Condition": {
        "StringNotEquals": {
          "iam:PassedToService": "cognito-idp.amazonaws.com"
        }
      }
    },
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::terraform-state-bucket/*"
    }
  ]
}
```

### Step 3: Use the Deployment Role

```bash
# Assume the deployment role
aws sts assume-role \
  --role-arn arn:aws:iam::821850226835:role/employee-portal-deployer \
  --role-session-name terraform-deploy \
  --external-id employee-portal-deploy

# Export credentials (from assume-role output)
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...

# Deploy
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
terraform apply
```

## Why This Is Secure

### ✅ Defense in Depth (Multiple Layers)

1. **Narrow Resource Scope:**
   - Only specific Cognito User Pool
   - Only specific IAM role
   - No wildcards

2. **Service Restriction:**
   - Can only pass role to Cognito
   - Explicit deny for other services
   - Prevents lateral movement

3. **Explicit Deny:**
   - Even if Allow is changed, Deny takes precedence
   - Protection against policy mistakes

4. **External ID:**
   - Prevents confused deputy attack
   - Additional authentication factor

5. **Audit Trail:**
   - CloudTrail logs all AssumeRole calls
   - CloudTrail logs all PassRole actions
   - Can track who deployed what

### ❌ What This Prevents

**Attack 1: Pass Different Role**
```
Attacker: "I'll pass a different admin role"
AWS: ❌ Denied (Resource restriction)
```

**Attack 2: Pass to Different Service**
```
Attacker: "I'll pass this role to Lambda"
AWS: ❌ Denied (Service condition + explicit deny)
```

**Attack 3: Modify Role Permissions**
```
Attacker: "I'll make the SMS role an admin role"
AWS: ❌ Denied (No iam:AttachRolePolicy permission)
```

**Attack 4: Create Powerful Role and Pass It**
```
Attacker: "I'll create admin-role and pass it"
AWS: ❌ Denied (Can only manage employee-portal-cognito-sms-role)
```

## Alternative: Use CloudFormation StackSets

If you want even more control:

```yaml
# cloudformation-deployment-role.yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Deployment role for Cognito SMS MFA

Resources:
  DeploymentRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: employee-portal-deployer
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: cloudformation.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: CognitoSMSDeployment
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - cognito-idp:UpdateUserPool
                  - cognito-idp:DescribeUserPool
                Resource: !Sub 'arn:aws:cognito-idp:${AWS::Region}:${AWS::AccountId}:userpool/us-east-1_kF4pcrUVF'
              - Effect: Allow
                Action:
                  - iam:CreateRole
                  - iam:GetRole
                  - iam:PutRolePolicy
                Resource: !Sub 'arn:aws:iam::${AWS::AccountId}:role/employee-portal-cognito-sms-role'
              - Effect: Allow
                Action: iam:PassRole
                Resource: !Sub 'arn:aws:iam::${AWS::AccountId}:role/employee-portal-cognito-sms-role'
                Condition:
                  StringEquals:
                    'iam:PassedToService': cognito-idp.amazonaws.com

# Deploy with:
# aws cloudformation create-stack \
#   --stack-name employee-portal-deployer \
#   --template-body file://cloudformation-deployment-role.yaml \
#   --capabilities CAPABILITY_NAMED_IAM
```

Then deploy Terraform using CloudFormation's role:
```bash
terraform apply \
  -var="role_arn=arn:aws:iam::821850226835:role/employee-portal-deployer"
```

## Comparison with Other Approaches

| Approach | Security | Complexity | PassRole? |
|----------|----------|------------|-----------|
| **No PassRole** | ❌ Not possible | N/A | Required |
| **Wildcard PassRole** | ❌ Very insecure | Low | Yes (bad) |
| **Scoped PassRole** | ✅ Secure | Low | Yes (good) |
| **Deployment Role** | ✅ Very secure | Medium | Yes (isolated) |
| **CloudFormation** | ✅ Very secure | High | Yes (delegated) |
| **Service-Linked Roles** | ✅ Most secure | N/A | No (but not available) |

## Why PassRole Can't Be Avoided

PassRole is **fundamental to AWS IAM security**. Here's why:

1. **Prevents Privilege Escalation:**
   Without it, anyone who can create roles could escalate privileges

2. **Enforces Separation of Duties:**
   Creating a role ≠ Permission to use that role

3. **Provides Audit Trail:**
   Every PassRole action is logged in CloudTrail

4. **Enables Least Privilege:**
   Forces you to explicitly grant role assignment permissions

**AWS's position:** PassRole is a feature, not a bug. It's secure by design when used correctly.

## Real-World Analogy

Think of it like a company:

- **Without PassRole:** Anyone can create a "VP" badge and wear it (insecure)
- **With PassRole:** You can create badges, but only HR can assign them (secure)

The security isn't in eliminating badge creation - it's in controlling who can assign badges to whom.

## Bottom Line

**There is no "better" way than PassRole for this use case** - it's the AWS-designed security mechanism.

The question isn't "how to avoid PassRole" but "how to scope PassRole correctly":

✅ **Good:** Narrow resource + service condition + explicit deny
❌ **Bad:** Broad resource + no conditions

Our implementation uses the good pattern.

## Recommended Action

**For immediate deployment:**
1. Create deployment role with scoped PassRole (as shown above)
2. Use that role to run `terraform apply`
3. Document the role and its purpose

**For long-term:**
1. Consider moving to CloudFormation/CDK for automated deployments
2. Add MFA requirement to deployment role assumption
3. Set up CloudTrail alerts for PassRole actions
4. Regular audit of who has deployment role access

---

**Key Takeaway:** PassRole is not insecure. Overly broad PassRole permissions are insecure. Our scoped approach is following AWS security best practices.
