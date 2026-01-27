# Migration to us-west-2

## What's Changing

This Terraform apply will:

1. **Destroy all resources in us-east-1:**
   - VPC, subnets, security groups
   - Application Load Balancer (ALB)
   - Cognito User Pool and users
   - EC2 portal instance
   - All networking infrastructure

2. **Create everything fresh in us-west-2:**
   - New VPC (10.0.0.0/16)
   - New ALB with HTTPS (port 443)
   - New Cognito User Pool
   - 5 users with password: `SecurePass123!`
   - New EC2 t3.micro portal instance
   - All supporting infrastructure

## Users Created

All users will have the password: **SecurePass123!**

| Email | Groups | Role |
|-------|--------|------|
| dmar@capsule.com | engineering, admins | Admin user |
| jahn@capsule.com | engineering, admins | Admin user |
| ahatcher@capsule.com | hr | HR user |
| peter@capsule.com | automation | Automation user |
| sdedakia@capsule.com | product | Product user |

## DNS Update Required

After Terraform completes, you'll need to update your Route53 DNS record for portal.capsule-playground.com to point to the new ALB in us-west-2.

**Terraform will automatically create the Route53 A record pointing to the new ALB.**

## Region Configuration

- **Old Region:** us-east-1
- **New Region:** us-west-2
- **AMI:** Ubuntu 22.04 LTS (ami-0aff18ec83b712f05)
- **Availability Zones:** us-west-2a, us-west-2b

## EC2 Instance Details

- **Type:** t3.micro
- **VCPUs:** 2
- **RAM:** 1 GB
- **Cost:** ~$7.50/month

## After Deployment

Once Terraform completes:

1. **Wait 5-10 minutes** for the portal instance to bootstrap
2. **Deploy the application code:**
   ```bash
   ./deploy-portal.sh i-XXXXXXXXXXXXX
   ```
3. **Test the portal:**
   - Navigate to https://portal.capsule-playground.com
   - Login with dmar@capsule.com / SecurePass123!
   - Verify EC2 Resources tab is visible
   - Test the EC2 instance redirects

## EC2 Resources Feature

The portal includes the new EC2 Resources management feature:

- **Page:** EC2 Resources (admin-only, between Directory and Engineering tabs)
- **Features:**
  - View all EC2 instances tagged with `VibeCodeArea`
  - Add new instances via the portal
  - Refresh instance data on-demand
  - Instances mapped to tabs redirect to AWS SSM Session Manager

## Tagged Instances

These instances are already tagged and will appear in the EC2 Resources page:

| Instance ID | Area | Tab |
|-------------|------|-----|
| i-0d1e3b59f57974076 | engineering | Engineering |
| i-06883f2837f77f365 | hr | HR |
| i-0966d965518d2dba1 | product | Product |

## Deployment Script

The deployment script (`deploy-portal.sh`) will:
1. Extract app.py and all templates from user_data.sh
2. Substitute the correct User Pool ID and AWS region
3. Create a deployment tarball
4. Provide instructions for deployment to the portal instance

## Rollback Plan

If you need to rollback:

```bash
# Change region back to us-east-1
# Edit variables.tf: default = "us-east-1"
# Edit main.tf: availability_zones and ubuntu_ami back to us-east-1

# Then run:
terraform apply
```

Note: This will destroy us-west-2 resources and recreate in us-east-1.

## Estimated Apply Time

- **Destroy phase:** ~2-3 minutes
- **Create phase:** ~5-7 minutes
- **Total:** ~10 minutes

## Warnings to Expect

You may see warnings about:
- Cognito MFA configuration (can be ignored)
- Resource targeting (if using -target flag)
- Route53 zone lookups

These are normal and won't affect the deployment.
