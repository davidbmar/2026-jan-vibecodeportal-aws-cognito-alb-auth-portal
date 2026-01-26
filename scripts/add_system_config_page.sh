#!/bin/bash
set -e

echo "Adding System Configuration page to Employee Portal..."

# Get instance information from Terraform
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
INSTANCE_ID=$(terraform output -json 2>/dev/null | jq -r '.ec2_instance_id.value // empty')
INSTANCE_IP=$(terraform output -json 2>/dev/null | jq -r '.ec2_private_ip.value // empty')
ALB_DNS=$(terraform output -json 2>/dev/null | jq -r '.alb_dns_name.value // empty')
PORTAL_URL=$(terraform output -json 2>/dev/null | jq -r '.portal_url.value // empty')

echo "Target Instance: $INSTANCE_ID ($INSTANCE_IP)"
echo "ALB DNS: $ALB_DNS"
echo "Portal URL: $PORTAL_URL"

# Add system configuration route to app.py on the remote instance
echo "Adding /system-config route to app.py..."

sudo tee /tmp/system_config_route.py > /dev/null << 'EOFROUTE'

@app.get("/system-config", response_class=HTMLResponse)
async def system_config(request: Request):
    """System configuration and architecture diagram."""
    email, groups = require_auth(request)

    # Gather system information
    import socket
    import subprocess
    import requests
    from datetime import datetime

    try:
        # Get current instance metadata
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

        public_ipv4 = requests.get(
            "http://169.254.169.254/latest/meta-data/public-ipv4",
            headers=headers, timeout=1
        ).text
    except:
        instance_id = "unknown"
        instance_type = "unknown"
        availability_zone = "unknown"
        local_ipv4 = "unknown"
        public_ipv4 = "unknown"

    hostname = socket.gethostname()

    # Get ALB information from headers
    alb_target_group = request.headers.get("x-amzn-trace-id", "unknown")

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

EOFROUTE

# SSH to the instance and update the app
echo "Updating app on EC2 instance $INSTANCE_ID..."

# Note: This requires SSH access to the instance
# For now, we'll create the files locally that can be manually deployed

echo ""
echo "Files created. To deploy to the portal instance:"
echo "1. SSH to the portal instance: ssh -i <your-key>.pem ubuntu@$INSTANCE_IP"
echo "2. Or use Systems Manager Session Manager"
echo "3. Then run: sudo systemctl restart employee-portal"
