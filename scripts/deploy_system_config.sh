#!/bin/bash
set -e

echo "========================================"
echo "Deploying System Configuration Page"
echo "========================================"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Get instance information from Terraform
cd "$PROJECT_ROOT/terraform/envs/tier5"
INSTANCE_ID=$(terraform output -json 2>/dev/null | jq -r '.ec2_instance_id.value // empty')
REGION=$(terraform output -json 2>/dev/null | jq -r '.aws_region.value // "us-east-1"')

if [ -z "$INSTANCE_ID" ]; then
    echo "❌ Error: Could not find EC2 instance ID from Terraform"
    echo "Make sure you're in the correct directory and Terraform state exists"
    exit 1
fi

echo "📍 Target Instance: $INSTANCE_ID"
echo "📍 Region: $REGION"
echo ""

# Check if AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI not found"
    echo "Please install AWS CLI: https://aws.amazon.com/cli/"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ Error: AWS credentials not configured"
    echo "Please run: aws configure"
    exit 1
fi

echo "✓ AWS CLI configured"
echo ""

# Create temporary directory for deployment files
TMP_DIR=$(mktemp -d)
echo "📦 Preparing deployment files in $TMP_DIR"

# Copy template file
cp "$PROJECT_ROOT/app/templates/system_config.html" "$TMP_DIR/"

# Create the app update script
cat > "$TMP_DIR/update_app.sh" << 'EOFUPDATE'
#!/bin/bash
set -e

echo "Updating Employee Portal with System Configuration page..."

# Backup current app.py
sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup.$(date +%Y%m%d_%H%M%S)

# Copy new template
sudo cp /tmp/system_config.html /opt/employee-portal/templates/

# Add the new route to app.py
# Find the line with the last route definition and insert before it
sudo tee -a /opt/employee-portal/app.py > /dev/null << 'EOFROUTE'

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

EOFROUTE

# Update base.html to add System Config link to navigation
sudo sed -i 's|<a href="/areas/product">Product</a>|<a href="/areas/product">Product</a>\n        <a href="/system-config" style="border-left: 2px solid rgba(255, 255, 255, 0.3);">System Config</a>|' /opt/employee-portal/templates/base.html

# Set proper ownership
sudo chown -R app:app /opt/employee-portal

# Restart the service
echo "Restarting employee-portal service..."
sudo systemctl restart employee-portal

# Wait for service to start
sleep 3

# Check service status
if sudo systemctl is-active --quiet employee-portal; then
    echo "✓ Service restarted successfully"
    sudo systemctl status employee-portal --no-pager -l | head -15
else
    echo "❌ Service failed to start. Check logs:"
    sudo journalctl -u employee-portal -n 50 --no-pager
    exit 1
fi

echo ""
echo "✓ Deployment complete!"
echo "Access the System Configuration page at: /system-config"

# Cleanup
rm -f /tmp/system_config.html /tmp/update_app.sh

EOFUPDATE

chmod +x "$TMP_DIR/update_app.sh"

echo ""
echo "🚀 Deploying via AWS Systems Manager Session Manager..."
echo ""

# Copy files to instance
echo "📤 Uploading template file..."
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo 'Receiving files...'\"]" \
    --region "$REGION" \
    --output text \
    --query 'Command.CommandId' > /dev/null 2>&1 || {
        echo "⚠️  Warning: Could not use SSM. Trying alternative method..."
        echo ""
        echo "======================================================================"
        echo "MANUAL DEPLOYMENT INSTRUCTIONS"
        echo "======================================================================"
        echo ""
        echo "The deployment files are ready at: $TMP_DIR"
        echo ""
        echo "To deploy manually:"
        echo ""
        echo "1. Copy files to the portal instance using one of these methods:"
        echo ""
        echo "   Option A - Using SCP (if you have SSH key):"
        echo "   scp -i your-key.pem $TMP_DIR/system_config.html ec2-user@<instance-ip>:/tmp/"
        echo "   scp -i your-key.pem $TMP_DIR/update_app.sh ec2-user@<instance-ip>:/tmp/"
        echo ""
        echo "   Option B - Using AWS Systems Manager Session Manager:"
        echo "   aws ssm start-session --target $INSTANCE_ID --region $REGION"
        echo ""
        echo "2. Then on the instance, run:"
        echo "   chmod +x /tmp/update_app.sh"
        echo "   /tmp/update_app.sh"
        echo ""
        echo "======================================================================"
        exit 0
    }

# Upload template file
aws s3 cp "$TMP_DIR/system_config.html" "s3://temp-deployment-$(date +%s)/system_config.html" 2>/dev/null || {
    echo "Creating deployment package..."

    # Encode files as base64 for transfer
    TEMPLATE_B64=$(base64 -w 0 "$TMP_DIR/system_config.html")
    UPDATE_SCRIPT_B64=$(base64 -w 0 "$TMP_DIR/update_app.sh")

    # Create deployment command
    DEPLOY_COMMAND="
echo '$TEMPLATE_B64' | base64 -d > /tmp/system_config.html
echo '$UPDATE_SCRIPT_B64' | base64 -d > /tmp/update_app.sh
chmod +x /tmp/update_app.sh
/tmp/update_app.sh
"

    # Execute via SSM
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$DEPLOY_COMMAND\"]" \
        --region "$REGION" \
        --output text \
        --query 'Command.CommandId')

    if [ -n "$COMMAND_ID" ]; then
        echo "✓ Deployment command sent: $COMMAND_ID"
        echo ""
        echo "⏳ Waiting for deployment to complete..."

        # Wait for command to complete
        for i in {1..30}; do
            STATUS=$(aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --region "$REGION" \
                --query 'Status' \
                --output text 2>/dev/null || echo "Pending")

            if [ "$STATUS" == "Success" ]; then
                echo ""
                echo "✅ Deployment successful!"
                echo ""
                aws ssm get-command-invocation \
                    --command-id "$COMMAND_ID" \
                    --instance-id "$INSTANCE_ID" \
                    --region "$REGION" \
                    --query 'StandardOutputContent' \
                    --output text
                break
            elif [ "$STATUS" == "Failed" ]; then
                echo ""
                echo "❌ Deployment failed!"
                echo ""
                aws ssm get-command-invocation \
                    --command-id "$COMMAND_ID" \
                    --instance-id "$INSTANCE_ID" \
                    --region "$REGION" \
                    --query 'StandardErrorContent' \
                    --output text
                exit 1
            fi

            echo -n "."
            sleep 2
        done
    fi
}

# Cleanup
rm -rf "$TMP_DIR"

echo ""
echo "✅ System Configuration page has been deployed!"
echo ""
echo "🌐 Access it at: https://portal.capsule-playground.com/system-config"
echo ""
