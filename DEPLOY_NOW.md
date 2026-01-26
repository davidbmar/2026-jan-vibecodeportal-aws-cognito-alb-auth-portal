# Deploy System Configuration Page - Quick Start

## Files Ready for Deployment

All files have been created in: `/home/ubuntu/cognito_alb_ec2/app/`

## Manual Deployment (Copy-Paste Method)

Since AWS SSM is not configured on the portal instance, use this simple copy-paste method:

### Step 1: Get Portal Instance Information

```bash
# The portal instance is:
Instance ID: i-09076e5809793e2eb
Private IP: 10.0.1.131
```

### Step 2: Connect to Portal Instance

You need to connect to the portal instance. Options:

#### Option A: AWS Console Session Manager
1. Go to: https://console.aws.amazon.com/ec2
2. Select instance `i-09076e5809793e2eb`
3. Click "Connect" → "Session Manager" → "Connect"

#### Option B: SSH (if you have the key)
```bash
# If you have SSH key configured:
ssh -i ~/.ssh/your-key.pem ubuntu@10.0.1.131
```

### Step 3: Run Deployment Commands

Once connected to the portal instance, copy and paste this entire block:

```bash
#!/bin/bash
set -e

echo "📦 Deploying System Configuration page..."

# Backup app.py
sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup.$(date +%Y%m%d_%H%M%S)

# Create template
sudo tee /opt/employee-portal/templates/system_config.html > /dev/null << 'EOFTEMPLATE'
{% extends "base.html" %}
{% block title %}SYSTEM CONFIGURATION - CAPSULE PORTAL{% endblock %}
{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
 ███████╗██╗   ██╗███████╗████████╗███████╗███╗   ███╗
 ██╔════╝╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔════╝████╗ ████║
 ███████╗ ╚████╔╝ ███████╗   ██║   █████╗  ██╔████╔██║
 ╚════██║  ╚██╔╝  ╚════██║   ██║   ██╔══╝  ██║╚██╔╝██║
 ███████║   ██║   ███████║   ██║   ███████╗██║ ╚═╝ ██║
 ╚══════╝   ╚═╝   ╚══════╝   ╚═╝   ╚══════╝╚═╝     ╚═╝
    </pre>
    <div class="content-box">
        <h2>⚙ SYSTEM CONFIGURATION & ARCHITECTURE</h2>
        <div class="info-section">
            <h3>📊 CURRENT SYSTEM STATUS</h3>
            <table style="width: 100%; margin-top: 1rem; font-size: 0.9rem;">
                <tr><td style="padding: 0.5rem;"><strong>Instance ID:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.instance_id }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>Instance Type:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.instance_type }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>Availability Zone:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.availability_zone }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>Private IP:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.private_ip }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>Public IP:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.public_ip }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>Hostname:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.hostname }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>User Pool ID:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace; font-size: 0.75rem;">{{ system_info.user_pool_id }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>AWS Region:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.aws_region }}</td></tr>
                <tr><td style="padding: 0.5rem;"><strong>System Time:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.current_time }}</td></tr>
            </table>
        </div>
        <div class="info-section" style="margin-top: 2rem;">
            <h3>🗺 INFRASTRUCTURE ARCHITECTURE MAP</h3>
            <pre style="font-family: 'Courier Prime', monospace; font-size: 0.7rem; line-height: 1.3; overflow-x: auto; background: rgba(0, 0, 0, 0.5); padding: 1.5rem; border: 1px solid rgba(0, 255, 0, 0.3);">
┌──────────────────────────────────────────────────────────────┐
│              CAPSULE ACCESS PORTAL ARCHITECTURE               │
└──────────────────────────────────────────────────────────────┘

                      Internet (Users)
                           │ HTTPS
                           ▼
         ┌─────────────────────────────────────┐
         │       Route53 DNS                   │
         │  portal.capsule-playground.com      │
         └────────────┬────────────────────────┘
                      │
 ╔════════════════════▼══════════════════════════════════╗
 ║            VPC: 10.0.0.0/16                          ║
 ║                                                       ║
 ║  ┌─────────────────────────────────────────────┐    ║
 ║  │  Application Load Balancer                  │    ║
 ║  │  • HTTPS (443) + Cognito Auth              │    ║
 ║  └──────────────┬──────────────────────────────┘    ║
 ║                 │ Port 8000                          ║
 ║                 ▼                                     ║
 ║  ┌─────────────────────────────────────────────┐    ║
 ║  │  EC2: {{ system_info.instance_id }}         │    ║
 ║  │  FastAPI App                                 │    ║
 ║  │  IP: {{ system_info.private_ip }}           │    ║
 ║  └─────────────────────────────────────────────┘    ║
 ╚═══════════════════════════════════════════════════════╝
                      │ AWS API
                      ▼
      ┌────────────────────────────────┐
      │   AWS Cognito User Pool        │
      │   Authentication & Groups      │
      └────────────────────────────────┘

KEY FEATURES:
• ALB handles authentication (Cognito OAuth2)
• App handles authorization (group-based)
• Instance ID targeting (resilient to IP changes)
• MFA enabled • Session caching • HTTPS with ACM
            </pre>
        </div>
        <div class="info-section" style="margin-top: 2rem;">
            <h3>🏗 INFRASTRUCTURE COMPONENTS</h3>
            <table style="width: 100%; margin-top: 1rem;">
                <thead><tr><th>Component</th><th>Purpose</th><th>Status</th></tr></thead>
                <tbody>
                    <tr><td>Route53</td><td>DNS</td><td><span style="color: #00ff00;">● Active</span></td></tr>
                    <tr><td>ALB</td><td>Traffic & Auth</td><td><span style="color: #00ff00;">● Running</span></td></tr>
                    <tr><td>EC2</td><td>FastAPI App</td><td><span style="color: #00ff00;">● Running</span></td></tr>
                    <tr><td>Cognito</td><td>Authentication</td><td><span style="color: #00ff00;">● Active</span></td></tr>
                </tbody>
            </table>
        </div>
        <div class="nav-links" style="margin-top: 3rem;">
            <a href="/">← RETURN TO HOME</a>
        </div>
    </div>
</div>
{% endblock %}
EOFTEMPLATE

# Add route to app.py
sudo tee -a /opt/employee-portal/app.py > /dev/null << 'EOFROUTE'

@app.get("/system-config", response_class=HTMLResponse)
async def system_config(request: Request):
    """System configuration and architecture diagram."""
    email, groups = require_auth(request)
    import socket
    from datetime import datetime
    try:
        import requests
        token = requests.put("http://169.254.169.254/latest/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"}, timeout=1).text
        hdrs = {"X-aws-ec2-metadata-token": token}
        instance_id = requests.get("http://169.254.169.254/latest/meta-data/instance-id", headers=hdrs, timeout=1).text
        instance_type = requests.get("http://169.254.169.254/latest/meta-data/instance-type", headers=hdrs, timeout=1).text
        availability_zone = requests.get("http://169.254.169.254/latest/meta-data/placement/availability-zone", headers=hdrs, timeout=1).text
        local_ipv4 = requests.get("http://169.254.169.254/latest/meta-data/local-ipv4", headers=hdrs, timeout=1).text
        try:
            public_ipv4 = requests.get("http://169.254.169.254/latest/meta-data/public-ipv4", headers=hdrs, timeout=1).text
        except:
            public_ipv4 = "N/A"
    except:
        instance_id = instance_type = availability_zone = local_ipv4 = public_ipv4 = "unknown"
    system_info = {
        "instance_id": instance_id, "instance_type": instance_type,
        "availability_zone": availability_zone, "private_ip": local_ipv4,
        "public_ip": public_ipv4, "hostname": socket.gethostname(),
        "current_time": datetime.utcnow().isoformat() + "Z",
        "user_pool_id": USER_POOL_ID, "aws_region": AWS_REGION
    }
    return templates.TemplateResponse("system_config.html", {
        "request": request, "email": email, "groups": groups, "system_info": system_info
    })

EOFROUTE

# Update navigation
sudo sed -i 's|<a href="/areas/product">Product</a>|<a href="/areas/product">Product</a>\n        <a href="/system-config" style="border-left: 2px solid rgba(255, 255, 255, 0.3);">System Config</a>|' /opt/employee-portal/templates/base.html

# Set permissions
sudo chown -R app:app /opt/employee-portal

# Restart service
sudo systemctl restart employee-portal
sleep 2

# Verify
if sudo systemctl is-active --quiet employee-portal; then
    echo ""
    echo "✅ DEPLOYMENT SUCCESSFUL!"
    echo ""
    sudo systemctl status employee-portal --no-pager | head -10
    echo ""
    echo "🌐 Access at: https://portal.capsule-playground.com/system-config"
else
    echo "❌ Service failed:"
    sudo journalctl -u employee-portal -n 20 --no-pager
fi
```

That's it! The entire deployment is one copy-paste operation.

## Verification

After running the above, test the portal:

```bash
# From the portal instance:
curl -I http://localhost:8000/system-config

# Should return HTTP 200 or 302 (redirect to auth)
```

Or visit in browser:
**https://portal.capsule-playground.com/system-config**

## What You'll See

After logging in to the portal:
- ✓ New "System Config" link in navigation bar
- ✓ Live system information (instance ID, IPs, etc.)
- ✓ ASCII art architecture diagram
- ✓ Component status table
- ✓ Infrastructure overview

## Rollback (if needed)

```bash
# Restore from backup
sudo cp /opt/employee-portal/app.py.backup.* /opt/employee-portal/app.py
sudo rm /opt/employee-portal/templates/system_config.html
sudo systemctl restart employee-portal
```

## Files Created on Management Server

- `/home/ubuntu/cognito_alb_ec2/app/templates/system_config.html` - Template
- `/home/ubuntu/cognito_alb_ec2/app/system_config_route.py` - Route code
- `/home/ubuntu/cognito_alb_ec2/scripts/deploy_system_config.sh` - Full deployment
- `/home/ubuntu/cognito_alb_ec2/scripts/quick_deploy.sh` - Quick deployment
- `/home/ubuntu/cognito_alb_ec2/SYSTEM_CONFIG_DEPLOYMENT.md` - Full guide
- `/home/ubuntu/cognito_alb_ec2/DEPLOY_NOW.md` - This file

## Need Help?

The portal instance ID is: **i-09076e5809793e2eb**

Connect via AWS Console → EC2 → Connect → Session Manager
