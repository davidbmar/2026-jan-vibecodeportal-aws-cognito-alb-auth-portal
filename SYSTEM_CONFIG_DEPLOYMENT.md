# System Configuration Page Deployment Guide

## What Was Created

A new **System Configuration** page for the Employee Portal that displays:

1. **Live System Information**
   - Instance ID, type, and availability zone
   - Private and public IP addresses
   - Hostname and current time
   - Cognito User Pool ID and AWS region

2. **Architecture Diagram**
   - ASCII art map of the infrastructure
   - Data flow diagram showing authentication flow
   - Security model overview

3. **Infrastructure Components**
   - Status of all AWS resources
   - Component purposes and current status

4. **Cost Estimate**
   - Monthly cost breakdown for all services

## Files Created

```
cognito_alb_ec2/
├── app/
│   ├── templates/
│   │   └── system_config.html          # New template with architecture map
│   └── system_config_route.py          # Python code to add to app.py
├── scripts/
│   ├── deploy_system_config.sh         # Automated deployment script
│   └── add_system_config_page.sh       # Alternative deployment helper
└── SYSTEM_CONFIG_DEPLOYMENT.md         # This file
```

## Deployment Options

### Option 1: Automated Deployment (AWS SSM)

If AWS Systems Manager Session Manager is configured:

```bash
cd ~/cognito_alb_ec2
./scripts/deploy_system_config.sh
```

This script will:
1. Get the EC2 instance ID from Terraform
2. Upload files via AWS SSM
3. Update app.py with the new route
4. Copy the template file
5. Update navigation in base.html
6. Restart the employee-portal service

### Option 2: Manual Deployment (Direct SSH)

If you have SSH access to the portal instance:

```bash
# 1. Get instance IP
cd ~/cognito_alb_ec2/terraform/envs/tier5
INSTANCE_IP=$(terraform output -json | jq -r '.ec2_private_ip.value')

# 2. Copy files (replace your-key.pem with your SSH key)
scp -i your-key.pem \
    ~/cognito_alb_ec2/app/templates/system_config.html \
    ubuntu@$INSTANCE_IP:/tmp/

# 3. SSH to instance
ssh -i your-key.pem ubuntu@$INSTANCE_IP

# 4. On the instance, run:
sudo cp /tmp/system_config.html /opt/employee-portal/templates/

# 5. Add the route to app.py
sudo tee -a /opt/employee-portal/app.py > /dev/null << 'EOF'

@app.get("/system-config", response_class=HTMLResponse)
async def system_config(request: Request):
    """System configuration and architecture diagram."""
    email, groups = require_auth(request)

    # Gather system information
    import socket
    from datetime import datetime

    try:
        # Get current instance metadata using IMDSv2
        import requests

        # Get IMDSv2 token
        ec2_metadata_token = requests.put(
            "http://169.254.169.254/latest/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
            timeout=1
        ).text

        headers = {"X-aws-ec2-metadata-token": ec2_metadata_token}

        instance_id = requests.get(
            "http://169.254.169.254/latest/meta-data/instance-id",
            headers=headers, timeout=1
        ).text

        instance_type = requests.get(
            "http://169.254.169.254/latest/meta-data/instance-type",
            headers=headers, timeout=1
        ).text

        availability_zone = requests.get(
            "http://169.254.169.254/latest/meta-data/placement/availability-zone",
            headers=headers, timeout=1
        ).text

        local_ipv4 = requests.get(
            "http://169.254.169.254/latest/meta-data/local-ipv4",
            headers=headers, timeout=1
        ).text

        try:
            public_ipv4 = requests.get(
                "http://169.254.169.254/latest/meta-data/public-ipv4",
                headers=headers, timeout=1
            ).text
        except:
            public_ipv4 = "N/A (private subnet)"

    except Exception as e:
        print(f"Error fetching instance metadata: {e}")
        instance_id = "unknown"
        instance_type = "unknown"
        availability_zone = "unknown"
        local_ipv4 = "unknown"
        public_ipv4 = "unknown"

    hostname = socket.gethostname()

    system_info = {
        "instance_id": instance_id,
        "instance_type": instance_type,
        "availability_zone": availability_zone,
        "private_ip": local_ipv4,
        "public_ip": public_ipv4,
        "hostname": hostname,
        "current_time": datetime.utcnow().isoformat() + "Z",
        "user_pool_id": USER_POOL_ID,
        "aws_region": AWS_REGION,
    }

    return templates.TemplateResponse("system_config.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "system_info": system_info
    })

EOF

# 6. Update navigation in base.html
sudo sed -i 's|<a href="/areas/product">Product</a>|<a href="/areas/product">Product</a>\n        <a href="/system-config" style="border-left: 2px solid rgba(255, 255, 255, 0.3);">System Config</a>|' /opt/employee-portal/templates/base.html

# 7. Set ownership
sudo chown -R app:app /opt/employee-portal

# 8. Restart service
sudo systemctl restart employee-portal

# 9. Check status
sudo systemctl status employee-portal
```

### Option 3: AWS Console Session Manager

1. Go to AWS EC2 Console
2. Select the employee-portal instance
3. Click "Connect" → "Session Manager"
4. Copy and paste the commands from Option 2 (steps 4-9)

## Verification

After deployment, verify the page is accessible:

```bash
# Check service status
curl -k https://portal.capsule-playground.com/system-config
```

Expected: HTTP 302 redirect to Cognito login (authentication required)

After logging in, you should see:
- Live system information table
- ASCII art architecture diagram
- Data flow diagram
- Infrastructure component status
- Cost estimates

## Features

### Dynamic Information
- Instance metadata fetched in real-time using EC2 IMDSv2
- Current timestamp (UTC)
- System hostname
- IP addresses (both private and public if available)

### Security
- Page requires authentication (no anonymous access)
- Uses existing auth middleware
- No sensitive credentials displayed
- Read-only view (no management functions)

### Styling
- Matches existing Matrix theme
- Responsive ASCII art diagrams
- Color-coded status indicators (green = active/healthy)
- Mobile-friendly tables

## Navigation

The new page is added to the navigation bar:

```
Home | Directory | Engineering | HR | Automation | Product | System Config
```

All authenticated users can access this page (no special group required).

## Troubleshooting

### Service Won't Start

Check logs:
```bash
sudo journalctl -u employee-portal -n 50 --no-pager
```

Common issues:
- Syntax error in app.py (check backup: app.py.backup.*)
- Missing template file (verify /opt/employee-portal/templates/system_config.html exists)
- Permissions (run: sudo chown -R app:app /opt/employee-portal)

### Page Shows "unknown" Values

- Instance metadata service may be blocked
- IMDSv2 token request failing
- Check security group allows internal metadata access

### Navigation Link Not Showing

- Clear browser cache
- Check base.html was updated correctly
- Restart service

## Rollback

If something goes wrong:

```bash
# Restore from backup
sudo cp /opt/employee-portal/app.py.backup.* /opt/employee-portal/app.py

# Remove the template
sudo rm /opt/employee-portal/templates/system_config.html

# Restart
sudo systemctl restart employee-portal
```

## Architecture Updates

This page documents your current architecture:

- **VPC**: 10.0.0.0/16
- **Subnets**: 10.0.1.0/24 (us-east-1a), 10.0.2.0/24 (us-east-1b)
- **ALB**: Handles authentication via Cognito
- **EC2**: Runs FastAPI app on port 8000
- **Cognito**: User pool for authentication and groups
- **Route53**: DNS for portal.capsule-playground.com

## Benefits

✓ **Transparency**: Users can see the infrastructure supporting the portal
✓ **Documentation**: Self-documenting architecture
✓ **Diagnostics**: Useful for troubleshooting IP changes or connectivity issues
✓ **Educational**: Shows how Cognito + ALB + EC2 integration works
✓ **Cost Awareness**: Monthly cost breakdown visible to stakeholders

## Next Steps

Consider adding:
- Real-time target health status from ALB
- Cognito user pool statistics (active users, groups)
- Application metrics (uptime, request count)
- CloudWatch dashboard integration
- Historical uptime data

---

**Created**: 2026-01-25
**Portal Version**: 1.0
**Deployment Method**: FastAPI route + Jinja2 template
