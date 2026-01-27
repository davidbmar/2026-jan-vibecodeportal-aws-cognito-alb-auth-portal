#!/bin/bash

# Quick deployment for password reset custom flow
set -e

INSTANCE_IP="35.88.161.244"
SSH_KEY="/home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem"

echo "================================================"
echo "Deploying Password Reset Custom Flow"
echo "================================================"

# Check if SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    exit 1
fi

echo "Testing SSH connection..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$INSTANCE_IP "echo 'Connected'" 2>/dev/null; then
    echo "ERROR: Cannot connect to instance"
    exit 1
fi

echo "Connected successfully!"
echo ""

# Extract app.py from user_data.sh (between 'cat > /opt/employee-portal/app.py' and 'EOFAPP')
echo "Extracting app.py from user_data.sh..."
sed -n '/^cat > \/opt\/employee-portal\/app\.py << .EOFAPP./,/^EOFAPP$/p' user_data.sh | \
    sed '1d;$d' > /tmp/deploy-app.py

# Extract templates
echo "Extracting templates..."
sed -n '/^cat > \/opt\/employee-portal\/templates\/password_reset\.html/,/^EOFRESETFLOW$/p' user_data.sh | \
    sed '1d;$d' > /tmp/password_reset.html

sed -n '/^cat > \/opt\/employee-portal\/templates\/password_reset_success\.html/,/^EOFRESETSUCC$/p' user_data.sh | \
    sed '1d;$d' > /tmp/password_reset_success.html

# Get terraform outputs for variable substitution
echo "Getting configuration values..."
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "us-west-2_wFv7AqBlg")
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "us-west-2")
CLIENT_ID=$(terraform output -raw cognito_client_id 2>/dev/null || echo "2hheaklvmfkpsm547p2nuab3r7")

echo "  User Pool ID: $USER_POOL_ID"
echo "  Region: $AWS_REGION"
echo "  Client ID: $CLIENT_ID"
echo ""

# Substitute variables in app.py
sed -i "s/\${user_pool_id}/$USER_POOL_ID/g" /tmp/deploy-app.py
sed -i "s/\${aws_region}/$AWS_REGION/g" /tmp/deploy-app.py
sed -i "s/\${client_id}/$CLIENT_ID/g" /tmp/deploy-app.py

echo "Uploading files to instance..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/deploy-app.py ubuntu@$INSTANCE_IP:/tmp/
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/password_reset.html ubuntu@$INSTANCE_IP:/tmp/
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/password_reset_success.html ubuntu@$INSTANCE_IP:/tmp/

echo "Installing files and restarting service..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP << 'EOFREMOTE'
# Backup existing files
sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup-$(date +%Y%m%d-%H%M%S)

# Install new files
sudo cp /tmp/deploy-app.py /opt/employee-portal/app.py
sudo cp /tmp/password_reset.html /opt/employee-portal/templates/
sudo cp /tmp/password_reset_success.html /opt/employee-portal/templates/

# Fix permissions
sudo chown app:app /opt/employee-portal/app.py
sudo chown app:app /opt/employee-portal/templates/password_reset*.html

# Restart service
sudo systemctl restart employee-portal

# Wait a moment for restart
sleep 2

# Check status
echo ""
echo "Service status:"
sudo systemctl status employee-portal --no-pager | head -15

echo ""
echo "Testing health endpoint..."
curl -s http://localhost:8000/health || echo "Health check failed"
EOFREMOTE

echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo ""
echo "New password reset flow is now available at:"
echo "  https://portal.capsule-playground.com/password-reset"
echo ""
echo "To test:"
echo "  1. Go to https://portal.capsule-playground.com/settings"
echo "  2. Click 'CHANGE PASSWORD'"
echo "  3. Follow the new progressive disclosure flow"
echo ""
