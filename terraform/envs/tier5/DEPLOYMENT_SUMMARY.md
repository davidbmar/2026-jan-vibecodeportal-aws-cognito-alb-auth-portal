# Portal Deployment Summary

## Deployment Status: ✅ COMPLETE

**Date**: 2026-01-26
**Region**: us-west-2
**Status**: Portal application successfully deployed and running

---

## Infrastructure Details

### Portal Instance
- **Instance ID**: i-07e3c8d3007cd48e1
- **Instance Type**: t3.micro (2 vCPU, 1 GB RAM)
- **Private IP**: 10.0.1.159
- **Public IP**: 34.216.14.31
- **SSH Key**: david-capsule-vibecode-2026-01-17.pem
- **Disk Size**: 100GB (gp3)
- **Operating System**: Ubuntu 24.04 LTS
- **Region**: us-west-2 (us-west-2a)

### Application
- **Service**: employee-portal.service
- **Status**: Active (running)
- **Port**: 8000 (internal)
- **User**: app
- **Working Directory**: /opt/employee-portal
- **Python**: 3.12 (venv)

### Load Balancer
- **URL**: https://portal.capsule-playground.com
- **Protocol**: HTTPS (port 443)
- **Target Group**: Port 8000
- **Health Checks**: Passing
- **Authentication**: AWS ALB + Cognito

### Cognito User Pool
- **Pool ID**: us-west-2_WePThH2J8
- **Users**: 5 (all passwords set to SecurePass123!)
- **MFA**: Optional (TOTP only, SMS disabled)

---

## Users and Access

### Admin Users (Can access EC2 Resources page)
| Email | Password | Groups |
|-------|----------|--------|
| dmar@capsule.com | SecurePass123! | engineering, admins |
| jahn@capsule.com | SecurePass123! | engineering, admins |

### Standard Users
| Email | Password | Groups |
|-------|----------|--------|
| ahatcher@capsule.com | SecurePass123! | hr |
| peter@capsule.com | SecurePass123! | automation |
| sdedakia@capsule.com | SecurePass123! | product |

---

## EC2 Resources Feature

### Tagged Instances
These instances are tagged with `VibeCodeArea` and will appear in the EC2 Resources page:

| Instance ID | Area | Tab | Status |
|-------------|------|-----|--------|
| i-0d1e3b59f57974076 | engineering | Engineering | Tagged ✅ |
| i-06883f2837f77f365 | hr | HR | Tagged ✅ |
| i-0966d965518d2dba1 | product | Product | Tagged ✅ |

### Feature Functionality
- **EC2 Resources Tab**: Visible only to admins (between Directory and Engineering tabs)
- **Instance Table**: Shows Name, Instance ID, Type, Public IP, Private IP, Mapped Area
- **Add Instance**: Admins can tag instances and map them to portal tabs
- **Refresh Button**: Fetches live data from EC2 API
- **Tab Redirects**: Engineering/HR/Product tabs redirect to AWS SSM Session Manager for mapped instances

---

## Deployed Files

```
/opt/employee-portal/
├── app.py                          # Main FastAPI application (23KB)
├── templates/
│   ├── base.html                   # Base template with navigation (14KB)
│   ├── home.html                   # Home page (1.3KB)
│   ├── directory.html              # User directory (644B)
│   ├── area.html                   # Area pages (521B)
│   ├── ec2_resources.html          # EC2 Resources management page (9.5KB) ✨ NEW
│   ├── denied.html                 # Access denied page (563B)
│   └── error.html                  # Error page (586B)
├── employee-portal.service         # Systemd service configuration (345B)
├── venv/                           # Python virtual environment
└── install.sh                      # Installation script (698B)

/etc/systemd/system/
└── employee-portal.service         # Systemd service (symlink)
```

---

## Security Configuration

### IAM Role Permissions
The portal instance has the following EC2 API permissions:
- ec2:DescribeInstances
- ec2:DescribeTags
- ec2:CreateTags
- ec2:DescribeInstanceStatus
- ec2:DescribeSecurityGroups

### Security Groups
**EC2 Security Group** (sg-0b8f050ce3b2a783b):
- **Inbound**:
  - Port 8000: From ALB security group
  - Port 22: From 44.244.76.51/32 (current instance)
- **Outbound**: All traffic

**ALB Security Group**:
- **Inbound**:
  - Port 443: From 0.0.0.0/0
- **Outbound**: To EC2 security group

### Network Configuration
- **VPC**: vpc-0b2126f3d25758cfa (10.0.0.0/16)
- **Public Subnets**:
  - subnet-02b587f43c08ac22f (us-west-2a)
  - subnet-09043e7f574ff3b32 (us-west-2b)
- **Internet Gateway**: Attached
- **Route53**: portal.capsule-playground.com → ALB

---

## Testing Checklist

### ✅ Completed Tests
- [x] Portal instance created with SSH key and 100GB disk
- [x] Application deployed via SSH
- [x] Service running (employee-portal.service active)
- [x] All templates deployed including ec2_resources.html
- [x] ALB health checks passing
- [x] Portal accessible at https://portal.capsule-playground.com
- [x] HTTP 302 redirect to Cognito login (authentication working)
- [x] EC2 instances tagged with VibeCodeArea

### 🔲 Pending Tests (User Should Verify)
- [ ] Login with admin user (dmar@capsule.com / SecurePass123!)
- [ ] "EC2 Resources" tab visible to admins
- [ ] Instance table displays 3 tagged instances
- [ ] "Refresh" button fetches live EC2 data
- [ ] "Add Instance" form validates and applies tags
- [ ] Engineering tab redirects to SSM for i-0d1e3b59f57974076
- [ ] HR tab redirects to SSM for i-06883f2837f77f365
- [ ] Product tab redirects to SSM for i-0966d965518d2dba1
- [ ] Non-admin users cannot see EC2 Resources tab
- [ ] Direct navigation to /ec2-resources redirects to /denied for non-admins

---

## Verification Commands

### Check Service Status
```bash
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@34.216.14.31
sudo systemctl status employee-portal
sudo journalctl -u employee-portal -f
```

### Test Local Access
```bash
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@34.216.14.31
curl http://localhost:8000/
```

### Check EC2 Tags
```bash
aws ec2 describe-instances \
  --region us-west-2 \
  --filters "Name=tag:VibeCodeArea,Values=*" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`VibeCodeArea`].Value|[0],State.Name]' \
  --output table
```

### View Application Logs
```bash
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@34.216.14.31
sudo journalctl -u employee-portal -n 100 --no-pager
```

---

## Troubleshooting

### Service Not Starting
```bash
# Check logs
sudo journalctl -u employee-portal -n 50

# Restart service
sudo systemctl restart employee-portal

# Check if port 8000 is in use
sudo lsof -i :8000
```

### EC2 Resources Page Errors
```bash
# Verify IAM role permissions
aws sts get-caller-identity
aws ec2 describe-instances --max-results 1

# Check app.py has correct User Pool ID
grep USER_POOL_ID /opt/employee-portal/app.py
```

### SSM Redirect Not Working
```bash
# Verify tagged instances exist
aws ec2 describe-instances \
  --region us-west-2 \
  --filters "Name=tag:VibeCodeArea,Values=engineering,hr,product" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`VibeCodeArea`].Value|[0]]'
```

---

## Access URLs

- **Portal**: https://portal.capsule-playground.com
- **EC2 Resources**: https://portal.capsule-playground.com/ec2-resources (admin only)
- **Directory**: https://portal.capsule-playground.com/directory
- **Engineering**: https://portal.capsule-playground.com/areas/engineering
- **HR**: https://portal.capsule-playground.com/areas/hr
- **Product**: https://portal.capsule-playground.com/areas/product

---

## Deployment History

### 2026-01-26 05:45 UTC
1. Created new portal instance with SSH key and 100GB disk
2. Deployed application via SSH (deployment package: 11.3KB compressed)
3. Installed systemd service
4. Verified service running and ALB health checks passing
5. All EC2 Resources feature files deployed successfully

### Changes from Previous Deployment
- Added SSH key: david-capsule-vibecode-2026-01-17.pem
- Increased disk: 8GB → 100GB
- Deployment method: SSM (failed due to permissions) → SSH (successful)
- Instance ID changed: i-05e5ad9868574ad07 → i-07e3c8d3007cd48e1
- Public IP changed: 16.148.199.21 → 34.216.14.31

---

## Cost Estimate

### Monthly Costs (us-west-2)
- **EC2 t3.micro**: $7.50/month
- **EBS gp3 100GB**: $8.00/month
- **ALB**: $16.20/month + $0.008/LCU-hour
- **Route53 Hosted Zone**: $0.50/month
- **Cognito**: Free tier (first 50,000 MAUs)
- **Data Transfer**: Variable

**Total**: ~$32/month + variable costs

---

## Next Steps

1. **Test the portal**: Login at https://portal.capsule-playground.com
2. **Verify EC2 Resources feature**:
   - Check "EC2 Resources" tab visibility for admins
   - Test instance table and refresh button
   - Test adding new instances
   - Verify tab redirects to SSM
3. **Optional: Add more users** via Cognito console
4. **Optional: Configure CloudWatch alarms** for monitoring
5. **Optional: Enable CloudTrail** for audit logging

---

## Support

For issues or questions:
1. Check service logs: `sudo journalctl -u employee-portal -f`
2. Verify ALB target group health in AWS Console
3. Check application logs in CloudWatch (if configured)

**Deployment Completed Successfully! 🎉**
