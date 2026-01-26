#!/bin/bash
set -e

INSTANCE_ID="i-09076e5809793e2eb"
REGION="us-east-1"

echo "🚀 Deploying System Configuration page to Employee Portal..."
echo "Instance: $INSTANCE_ID"
echo ""

# Create the deployment script
cat > /tmp/deploy_portal_update.sh << 'EOFSCRIPT'
#!/bin/bash
set -e

echo "📦 Installing System Configuration page..."

# Backup current app.py
echo "1. Backing up app.py..."
sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup.$(date +%Y%m%d_%H%M%S)

# Create the new template
echo "2. Creating system_config.html template..."
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

        <!-- Current System Information -->
        <div class="info-section">
            <h3>📊 CURRENT SYSTEM STATUS</h3>
            <table style="width: 100%; margin-top: 1rem; font-size: 0.9rem;">
                <tr>
                    <td style="padding: 0.5rem;"><strong>Instance ID:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.instance_id }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>Instance Type:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.instance_type }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>Availability Zone:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.availability_zone }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>Private IP:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.private_ip }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>Public IP:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.public_ip }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>Hostname:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace;">{{ system_info.hostname }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>User Pool ID:</strong></td>
                    <td style="padding: 0.5rem; font-family: 'Courier Prime', monospace; font-size: 0.75rem;">{{ system_info.user_pool_id }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>AWS Region:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.aws_region }}</td>
                </tr>
                <tr>
                    <td style="padding: 0.5rem;"><strong>System Time:</strong></td>
                    <td style="padding: 0.5rem;">{{ system_info.current_time }}</td>
                </tr>
            </table>
        </div>

        <!-- Architecture Diagram -->
        <div class="info-section" style="margin-top: 2rem;">
            <h3>🗺 INFRASTRUCTURE ARCHITECTURE MAP</h3>
            <pre style="font-family: 'Courier Prime', monospace; font-size: 0.7rem; line-height: 1.3; overflow-x: auto; background: rgba(0, 0, 0, 0.5); padding: 1.5rem; border: 1px solid rgba(0, 255, 0, 0.3);">
┌─────────────────────────────────────────────────────────────────────────┐
│                     CAPSULE ACCESS PORTAL ARCHITECTURE                   │
└─────────────────────────────────────────────────────────────────────────┘

                            Internet (Users)
                                  │
                                  │ HTTPS
                                  ▼
                ┌─────────────────────────────────┐
                │       Route53 DNS               │
                │ portal.capsule-playground.com   │
                └─────────────┬───────────────────┘
                              │
     ╔════════════════════════▼════════════════════════════════════╗
     ║                  VPC: 10.0.0.0/16                          ║
     ║                                                              ║
     ║  ┌──────────────────────────────────────────────────────┐  ║
     ║  │  Application Load Balancer                            │  ║
     ║  │  • HTTPS (port 443)                                   │  ║
     ║  │  • Cognito Authentication                            │  ║
     ║  │  • ACM Certificate                                    │  ║
     ║  └───────────────┬──────────────────────────────────────┘  ║
     ║                  │                                          ║
     ║                  │ Port 8000                                ║
     ║                  ▼                                          ║
     ║  ┌──────────────────────────────────────────────────────┐  ║
     ║  │  EC2 Instance: {{ system_info.instance_id }}         │  ║
     ║  │  • FastAPI Application                                │  ║
     ║  │  • Private IP: {{ system_info.private_ip }}          │  ║
     ║  │  • Security Group: ALB only                          │  ║
     ║  └──────────────────────────────────────────────────────┘  ║
     ╚══════════════════════════════════════════════════════════════╝
                              │
                              │ AWS API
                              ▼
                ┌─────────────────────────────────┐
                │     AWS Cognito User Pool        │
                │  • Authentication & MFA          │
                │  • Groups: eng, hr, product...  │
                └─────────────────────────────────┘
            </pre>
        </div>

        <!-- Infrastructure Components -->
        <div class="info-section" style="margin-top: 2rem;">
            <h3>🏗 INFRASTRUCTURE COMPONENTS</h3>
            <table style="width: 100%; margin-top: 1rem;">
                <thead>
                    <tr>
                        <th>Component</th>
                        <th>Purpose</th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody>
                    <tr>
                        <td>Route53</td>
                        <td>DNS management</td>
                        <td><span style="color: #00ff00;">● Active</span></td>
                    </tr>
                    <tr>
                        <td>ACM Certificate</td>
                        <td>SSL/TLS termination</td>
                        <td><span style="color: #00ff00;">● Valid</span></td>
                    </tr>
                    <tr>
                        <td>Application Load Balancer</td>
                        <td>Traffic & authentication</td>
                        <td><span style="color: #00ff00;">● Running</span></td>
                    </tr>
                    <tr>
                        <td>EC2 Instance</td>
                        <td>FastAPI application</td>
                        <td><span style="color: #00ff00;">● Running</span></td>
                    </tr>
                    <tr>
                        <td>Cognito User Pool</td>
                        <td>User authentication</td>
                        <td><span style="color: #00ff00;">● Active</span></td>
                    </tr>
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

# Add the route to app.py (append before the last line)
echo "3. Adding /system-config route to app.py..."
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
echo "4. Updating navigation menu..."
sudo sed -i 's|<a href="/areas/product">Product</a>|<a href="/areas/product">Product</a>\n        <a href="/system-config" style="border-left: 2px solid rgba(255, 255, 255, 0.3);">System Config</a>|' /opt/employee-portal/templates/base.html

# Set ownership
echo "5. Setting permissions..."
sudo chown -R app:app /opt/employee-portal

# Restart service
echo "6. Restarting service..."
sudo systemctl restart employee-portal

# Check status
sleep 2
if sudo systemctl is-active --quiet employee-portal; then
    echo ""
    echo "✅ Deployment successful!"
    echo ""
    sudo systemctl status employee-portal --no-pager -l | head -10
else
    echo "❌ Service failed. Check logs:"
    sudo journalctl -u employee-portal -n 30 --no-pager
    exit 1
fi

EOFSCRIPT

# Execute via SSM
echo "📤 Executing deployment on instance..."

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$(cat /tmp/deploy_portal_update.sh | sed 's/"/\\"/g')\"]" \
    --region "$REGION" \
    --output text \
    --query 'Command.CommandId' 2>&1)

if [ $? -eq 0 ]; then
    echo "✓ Command sent: $COMMAND_ID"
    echo "⏳ Waiting for completion..."

    for i in {1..30}; do
        sleep 2
        STATUS=$(aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")

        echo -n "."

        if [ "$STATUS" == "Success" ]; then
            echo ""
            echo ""
            echo "✅ DEPLOYMENT SUCCESSFUL!"
            echo ""
            aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --region "$REGION" \
                --query 'StandardOutputContent' \
                --output text
            echo ""
            echo "🌐 Access the System Configuration page at:"
            echo "   https://portal.capsule-playground.com/system-config"
            echo ""
            exit 0
        elif [ "$STATUS" == "Failed" ]; then
            echo ""
            echo "❌ DEPLOYMENT FAILED!"
            aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --region "$REGION" \
                --query 'StandardErrorContent' \
                --output text
            exit 1
        fi
    done

    echo ""
    echo "⏱ Timeout waiting for deployment. Check AWS Console for command status."
else
    echo "❌ Failed to send SSM command. Error: $COMMAND_ID"
    echo ""
    echo "Alternative: See SYSTEM_CONFIG_DEPLOYMENT.md for manual deployment steps"
fi
