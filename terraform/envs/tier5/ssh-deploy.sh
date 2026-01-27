#!/bin/bash

# SSH Deployment Script for Portal Application
# This deploys the portal application via SSH to the new instance

set -e

INSTANCE_IP="34.216.14.31"
SSH_KEY="/home/ubuntu/.ssh/david-capsule-vibecode-2026-01-17.pem"
DEPLOYMENT_PACKAGE="/tmp/portal-deploy.tar.gz"

echo "================================================"
echo "Portal Application SSH Deployment"
echo "================================================"
echo "Target Instance: $INSTANCE_IP"
echo "SSH Key: $SSH_KEY"
echo ""

# Check if SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    echo "Please ensure the key file exists and has correct permissions (chmod 400)"
    exit 1
fi

# Check if deployment package exists
if [ ! -f "$DEPLOYMENT_PACKAGE" ]; then
    echo "ERROR: Deployment package not found at $DEPLOYMENT_PACKAGE"
    exit 1
fi

echo "Waiting for instance to be accessible via SSH..."
echo "(This may take 2-3 minutes for initial bootstrap to complete)"
echo ""

# Wait for SSH to be available
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$INSTANCE_IP "echo 'SSH connection successful'" 2>/dev/null; then
        echo "SSH connection established!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT/$MAX_RETRIES - waiting for SSH..."
    sleep 10
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "ERROR: Could not establish SSH connection after $MAX_RETRIES attempts"
    exit 1
fi

echo ""
echo "Checking bootstrap completion..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP "while [ ! -f /tmp/bootstrap-complete ]; do echo 'Waiting for bootstrap...'; sleep 5; done; echo 'Bootstrap complete!'"

echo ""
echo "================================================"
echo "Uploading deployment package..."
echo "================================================"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$DEPLOYMENT_PACKAGE" ubuntu@$INSTANCE_IP:/tmp/

echo ""
echo "================================================"
echo "Extracting and installing application..."
echo "================================================"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP << 'EOFREMOTE'
cd /opt/employee-portal
sudo tar -xzf /tmp/portal-deploy.tar.gz
sudo chmod +x install.sh
sudo ./install.sh

echo ""
echo "Verifying service..."
sudo systemctl status employee-portal --no-pager

echo ""
echo "Testing local access..."
curl -s http://localhost:8000/ | head -20
EOFREMOTE

echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo ""
echo "Portal should now be accessible at:"
echo "  https://portal.capsule-playground.com"
echo ""
echo "Login with:"
echo "  Email: dmar@capsule.com"
echo "  Password: SecurePass123!"
echo ""
echo "Check EC2 Resources tab (admin only)"
echo ""
