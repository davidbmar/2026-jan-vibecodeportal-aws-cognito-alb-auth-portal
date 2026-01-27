# Employee Portal Deployment Guide

This guide explains how to deploy the new portal instance with the EC2 Resources management feature.

## What Changed

The original `user_data.sh` embedded application exceeded AWS's 16KB user_data limit after adding the EC2 Resources feature. The solution:

- **New file:** `portal-instance.tf` - Creates the portal EC2 instance
- **Updated file:** `main.tf` - Old instance definition commented out
- **Deployment script:** `deploy-portal.sh` - Extracts and deploys the application code

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform installed
- Access to deploy EC2 instances in your AWS account

## Deployment Steps

### Step 1: Create the Portal Instance

Run Terraform to create the new portal instance:

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Initialize if needed
terraform init

# Review the plan
terraform plan

# Apply - this will create the portal instance
terraform apply
```

**What this does:**
- Creates a new t3.micro EC2 instance named "employee-portal-portal"
- Installs Python, pip, and required dependencies
- Creates the app user and directory structure
- Does NOT deploy the application code yet (that's Step 2)

**Expected output:**
```
portal_instance_id = "i-xxxxxxxxxxxxx"
portal_private_ip = "10.0.x.x"
portal_public_ip = "x.x.x.x"
```

**Note the instance ID** - you'll need it for Step 2.

### Step 2: Deploy the Application Code

After the instance is running (wait 2-3 minutes after terraform apply):

```bash
# Run the deployment script with your instance ID
./deploy-portal.sh i-xxxxxxxxxxxxx
```

**What this does:**
- Extracts app.py and all templates from user_data.sh
- Substitutes User Pool ID and AWS Region
- Creates a deployment tarball at /tmp/portal-deploy.tar.gz
- Provides instructions for manual deployment

### Step 3: Manual Deployment (Required)

The script will output instructions similar to:

```bash
# 1. Copy the package to the instance (if you have SSH key)
scp -i YOUR_KEY.pem /tmp/portal-deploy.tar.gz ubuntu@<INSTANCE_IP>:/tmp/

# 2. SSH into the instance
ssh -i YOUR_KEY.pem ubuntu@<INSTANCE_IP>

# 3. Extract and install
cd /tmp && tar -xzf portal-deploy.tar.gz && sudo bash install.sh
```

**Alternative: Use SSM Session Manager (no SSH key needed):**

```bash
# Start a session
aws ssm start-session --target i-xxxxxxxxxxxxx

# Once connected, run:
cd /tmp
# You'll need to copy the tarball content or upload via S3
```

### Step 4: Verify Deployment

After deployment completes:

```bash
# Check service status
sudo systemctl status employee-portal

# Check logs
sudo journalctl -u employee-portal -f

# Test the API
curl http://localhost:8000/health
```

## Verification Checklist

After deployment, verify these features work:

1. **Portal loads:** Navigate to https://portal.capsule-playground.com
2. **Login works:** Sign in with an admin user (dmar@capsule.com or jahn@capsule.com)
3. **EC2 Resources tab visible:** Only visible to admins
4. **EC2 Resources page:**
   - Shows 3 tagged instances
   - Displays: Name, Instance ID, Type, IPs, Area, State
   - "Refresh" button works
   - "Add Instance" modal opens
5. **Tab redirects work:**
   - Click "Engineering" → redirects to SSM for i-0d1e3b59f57974076
   - Click "HR" → redirects to SSM for i-06883f2837f77f365
   - Click "Product" → redirects to SSM for i-0966d965518d2dba1

## Troubleshooting

### Instance not bootstrapped yet
**Error:** `Waiting for bootstrap to complete...`
**Solution:** Wait 2-3 minutes for the instance to finish installing dependencies

### Service won't start
```bash
# Check logs for errors
sudo journalctl -u employee-portal -n 50

# Common issues:
# - Missing dependencies: reinstall via venv
# - Port 8000 in use: check with `sudo lsof -i :8000`
# - Permission issues: verify `chown -R app:app /opt/employee-portal`
```

### ALB health checks failing
```bash
# Check if the app is responding
curl http://localhost:8000/health

# If not responding, check firewall
sudo ufw status

# Verify security group allows port 8000 from ALB
```

### EC2 Resources page shows no instances
**Issue:** IAM permissions or EC2 tags missing
**Solution:**
```bash
# Verify IAM role has EC2 permissions
aws iam get-role-policy --role-name employee-portal-ec2-role --policy-name employee-portal-ec2-cognito-policy

# Verify instances are tagged
aws ec2 describe-instances --filters "Name=tag:VibeCodeArea,Values=*" --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`VibeCodeArea`].Value|[0]]'
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Internet                             │
└─────────────────────────┬───────────────────────────────┘
                          │
                          ▼
            ┌─────────────────────────────┐
            │   Application Load Balancer  │
            │   (port 443 HTTPS)          │
            │   + Cognito Authentication   │
            └──────────────┬──────────────┘
                          │
                          ▼
            ┌─────────────────────────────┐
            │   Portal EC2 Instance       │
            │   t3.micro                  │
            │   FastAPI on port 8000      │
            │                             │
            │   Features:                 │
            │   - User management         │
            │   - EC2 Resources mgmt      │
            │   - SSM redirect            │
            └──────────────┬──────────────┘
                          │
                          ▼
            ┌─────────────────────────────┐
            │   AWS APIs                  │
            │   - Cognito (auth/users)    │
            │   - EC2 (instances/tags)    │
            └─────────────────────────────┘
```

## Cost Estimate

- **t3.micro instance:** ~$7.50/month
- **ALB:** ~$16/month (already running)
- **Data transfer:** ~$1-2/month
- **Total:** ~$8-10/month additional

## File Reference

- `portal-instance.tf` - EC2 instance definition
- `deploy-portal.sh` - Deployment automation script
- `user_data.sh` - Source of application code (too large for user_data)
- `main.tf` - Main infrastructure (old instance commented out)

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Review CloudWatch Logs (if configured)
3. Check ALB target group health in AWS Console
4. Verify Cognito User Pool configuration
