# AWS Systems Manager (SSM) Session Manager Setup Guide

## Overview

To enable browser-based terminal access via SSM Session Manager for the tagged EC2 instances, you need to:

1. Add SSM permissions to the IAM role attached to the instances
2. Ensure SSM Agent is running (usually pre-installed on modern Ubuntu/Amazon Linux)
3. Verify connectivity

---

## Tagged Instances That Need SSM Access

| Instance ID | Area | Tab | IAM Role |
|-------------|------|-----|----------|
| i-0d1e3b59f57974076 | engineering | Engineering | ssh-whitelist-role |
| i-06883f2837f77f365 | hr | HR | ssh-whitelist-role |
| i-0966d965518d2dba1 | product | Product | ssh-whitelist-role |

---

## Step 1: Add SSM Permissions to IAM Role

### Option A: Via AWS Console

1. **Go to IAM Console** → Roles
2. **Search for**: `ssh-whitelist-role`
3. **Click on the role**
4. **Click "Attach policies"**
5. **Search for and attach**: `AmazonSSMManagedInstanceCore`
6. **Click "Attach policy"**

### Option B: Via AWS CLI (if you have IAM permissions)

```bash
aws iam attach-role-policy \
  --role-name ssh-whitelist-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Option C: Via Terraform (recommended for infrastructure as code)

Add this to your Terraform configuration:

```hcl
# Attach SSM managed policy to existing role
resource "aws_iam_role_policy_attachment" "ssh_whitelist_ssm" {
  role       = "ssh-whitelist-role"
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

Then run:
```bash
terraform apply
```

---

## Step 2: Verify SSM Agent is Running

SSM Agent is pre-installed on:
- Amazon Linux 2/2023
- Ubuntu 16.04+ (via snap)
- Windows Server 2016+

### Check SSM Agent Status

SSH into each instance and run:

```bash
# For Ubuntu (snap version)
sudo snap services amazon-ssm-agent

# For Ubuntu (systemd version)
sudo systemctl status amazon-ssm-agent

# For Amazon Linux
sudo systemctl status amazon-ssm-agent
```

### Start SSM Agent if Stopped

```bash
# Ubuntu (snap)
sudo snap start amazon-ssm-agent

# Ubuntu/Amazon Linux (systemd)
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
```

---

## Step 3: Verify SSM Connectivity

### Via AWS Console

1. **Go to Systems Manager** → Session Manager
2. **Check "Managed instances"** tab
3. You should see the 3 instances listed with "Online" status
4. If not visible, wait 5-10 minutes after attaching the IAM policy

### Via AWS CLI

```bash
aws ssm describe-instance-information \
  --region us-west-2 \
  --filters "Key=InstanceIds,Values=i-0d1e3b59f57974076,i-06883f2837f77f365,i-0966d965518d2dba1" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' \
  --output table
```

Expected output:
```
------------------------------------------------------
|          DescribeInstanceInformation               |
+---------------------+---------+--------------------+
|  i-0d1e3b59f57974076|  Online |  Ubuntu            |
|  i-06883f2837f77f365|  Online |  Ubuntu            |
|  i-0966d965518d2dba1|  Online |  Ubuntu            |
+---------------------+---------+--------------------+
```

---

## Step 4: Test SSM Session Manager

### Via AWS Console

1. **Go to Systems Manager** → Session Manager
2. **Click "Start session"**
3. **Select one of the tagged instances** (e.g., i-0d1e3b59f57974076)
4. **Click "Start session"**
5. You should get a browser-based terminal

### Via Portal Application

1. **Login to portal**: https://portal.capsule-playground.com
2. **Login as admin**: dmar@capsule.com / SecurePass123!
3. **Click "Engineering" tab**
4. **Should redirect to**: AWS SSM Session Manager for i-0d1e3b59f57974076
5. **SSM page should load** with "Start session" button

---

## Required IAM Permissions

### For EC2 Instances (ssh-whitelist-role)

The IAM role attached to the EC2 instances needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

**Note**: These permissions are included in the AWS managed policy `AmazonSSMManagedInstanceCore`.

### For Users Starting Sessions

Users who want to start SSM sessions need:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession"
      ],
      "Resource": [
        "arn:aws:ec2:us-west-2:821850226835:instance/i-0d1e3b59f57974076",
        "arn:aws:ec2:us-west-2:821850226835:instance/i-06883f2837f77f365",
        "arn:aws:ec2:us-west-2:821850226835:instance/i-0966d965518d2dba1",
        "arn:aws:ssm:*:*:document/AWS-StartSSHSession"
      ]
    }
  ]
}
```

---

## Network Requirements

SSM Session Manager works over **outbound HTTPS** (port 443). No inbound ports need to be opened.

### Required Outbound Connectivity

Instances need outbound access to these AWS service endpoints:
- `ssm.us-west-2.amazonaws.com`
- `ssmmessages.us-west-2.amazonaws.com`
- `ec2messages.us-west-2.amazonaws.com`

### Check Outbound Connectivity

SSH into an instance and test:

```bash
# Test SSM endpoint
curl -I https://ssm.us-west-2.amazonaws.com

# Test SSM Messages endpoint
curl -I https://ssmmessages.us-west-2.amazonaws.com

# Test EC2 Messages endpoint
curl -I https://ec2messages.us-west-2.amazonaws.com
```

All should return `200 OK` or `403 Forbidden` (both indicate connectivity).

---

## Troubleshooting

### Issue 1: Instances Not Showing in "Managed Instances"

**Possible Causes**:
- IAM role missing SSM permissions
- SSM Agent not running
- No internet connectivity (check NAT gateway or internet gateway)
- Security group blocking outbound HTTPS (port 443)

**Solution**:
1. Verify IAM policy attached: `AmazonSSMManagedInstanceCore`
2. Check SSM Agent status: `sudo systemctl status amazon-ssm-agent`
3. Restart SSM Agent: `sudo systemctl restart amazon-ssm-agent`
4. Wait 5-10 minutes for instance to register
5. Check SSM Agent logs: `sudo journalctl -u amazon-ssm-agent -n 50`

### Issue 2: "Start Session" Button Grayed Out

**Cause**: You don't have IAM permissions to start sessions

**Solution**: Add `ssm:StartSession` permission to your IAM user/role

### Issue 3: Portal Redirect Shows Error Page

**Possible Causes**:
- Instance is stopped or terminated
- Instance exists in different region

**Solution**:
1. Check instance state: `aws ec2 describe-instances --instance-ids i-0d1e3b59f57974076 --region us-west-2`
2. Verify tags are correct: Check for `VibeCodeArea` tag
3. Check portal logs: `sudo journalctl -u employee-portal -f`

### Issue 4: "Session Could Not Be Started"

**Causes**:
- SSM Agent not running on target instance
- Network connectivity issues
- IAM role permissions missing

**Solution**:
1. SSH into instance: `ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@<instance-ip>`
2. Check SSM Agent: `sudo systemctl status amazon-ssm-agent`
3. View agent logs: `sudo journalctl -u amazon-ssm-agent -n 50`
4. Check connectivity: Test HTTPS access to SSM endpoints

---

## Session Logging (Optional)

To enable session logging for audit/compliance:

1. **Create S3 bucket** for session logs
2. **Go to Systems Manager** → Session Manager → Preferences
3. **Enable**: "CloudWatch logging" and/or "S3 logging"
4. **Select bucket**: Choose your logging bucket
5. **Save**

All SSM sessions will now be logged.

---

## Alternative: SSM Port Forwarding

If you prefer local terminal access instead of browser-based:

### Install Session Manager Plugin

```bash
# macOS
brew install --cask session-manager-plugin

# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb
```

### Start Session via CLI

```bash
aws ssm start-session \
  --target i-0d1e3b59f57974076 \
  --region us-west-2
```

### SSH over SSM (no open ports needed)

```bash
ssh -i ~/.ssh/your-key.pem \
  -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --region us-west-2" \
  ubuntu@i-0d1e3b59f57974076
```

---

## Quick Setup Checklist

- [ ] Attach `AmazonSSMManagedInstanceCore` policy to `ssh-whitelist-role`
- [ ] Wait 5-10 minutes for instances to register with SSM
- [ ] Verify instances show as "Online" in Systems Manager → Managed Instances
- [ ] Test "Start session" in AWS Console → Systems Manager → Session Manager
- [ ] Login to portal and click Engineering/HR/Product tabs to test redirects
- [ ] (Optional) Configure session logging in Session Manager preferences

---

## Verification Commands

```bash
# Check if IAM policy is attached
aws iam list-attached-role-policies --role-name ssh-whitelist-role

# Check SSM managed instances
aws ssm describe-instance-information \
  --region us-west-2 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' \
  --output table

# Start a session via CLI
aws ssm start-session --target i-0d1e3b59f57974076 --region us-west-2
```

---

## Cost

SSM Session Manager is **free** for basic usage. Optional features that incur costs:
- **Session logs to S3**: S3 storage costs (~$0.023/GB/month)
- **CloudWatch logs**: ~$0.50/GB ingested, ~$0.03/GB stored/month
- **VPC Endpoints** (if using private subnets without NAT): ~$7.30/month per endpoint

Basic redirect-to-SSM functionality from the portal has **zero additional cost**.

---

## Summary

Once you attach the `AmazonSSMManagedInstanceCore` policy to `ssh-whitelist-role`, the three tagged instances will automatically register with SSM within 5-10 minutes. After that:

1. **Engineering tab** → Redirects to SSM for i-0d1e3b59f57974076
2. **HR tab** → Redirects to SSM for i-06883f2837f77f365
3. **Product tab** → Redirects to SSM for i-0966d965518d2dba1

Users clicking these tabs will be taken to the AWS SSM Session Manager page where they can click "Start session" to get browser-based terminal access.
