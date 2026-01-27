#!/bin/bash

# Manual Deployment Helper Script
# This script provides the commands needed to deploy the portal application

set -e

INSTANCE_ID="${1:-i-05e5ad9868574ad07}"
REGION="us-west-2"

echo "================================================"
echo "Portal Application Manual Deployment"
echo "================================================"
echo "Instance: $INSTANCE_ID"
echo "Region: $REGION"
echo ""

# Check if deployment package exists
if [ ! -f /tmp/portal-deploy.tar.gz ]; then
    echo "ERROR: Deployment package not found at /tmp/portal-deploy.tar.gz"
    exit 1
fi

# Get instance status
echo "Checking instance status..."
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "error")

if [ "$INSTANCE_STATE" != "running" ]; then
    echo "ERROR: Instance is not running (state: $INSTANCE_STATE)"
    exit 1
fi

echo "Instance is running."
echo ""

# Generate base64 content for manual paste
echo "================================================"
echo "MANUAL DEPLOYMENT INSTRUCTIONS"
echo "================================================"
echo ""
echo "1. Open AWS Console → Systems Manager → Session Manager"
echo "2. Click 'Start session'"
echo "3. Select instance: $INSTANCE_ID"
echo "4. Click 'Start session'"
echo ""
echo "5. In the Session Manager terminal, run these commands:"
echo ""
echo "---------- COPY FROM HERE ----------"
echo ""

cat << 'EOFCMDS'
# Navigate to application directory
cd /opt/employee-portal

# Create base64 deployment package
cat > portal-deploy.tar.gz.b64 << 'EOFB64'
EOFCMDS

# Output the base64 content
cat /tmp/portal-deploy.b64

cat << 'EOFCMDS'
EOFB64

# Decode and extract
base64 -d portal-deploy.tar.gz.b64 > portal-deploy.tar.gz
rm portal-deploy.tar.gz.b64

# Extract deployment package
sudo tar -xzf portal-deploy.tar.gz

# Run installation
sudo chmod +x install.sh
sudo ./install.sh

# Verify service
sudo systemctl status employee-portal

# Test local access
curl http://localhost:8000/

echo ""
echo "Deployment complete!"
echo "Portal should be accessible at: https://portal.capsule-playground.com"
EOFCMDS

echo ""
echo "---------- COPY TO HERE ----------"
echo ""
echo "================================================"
echo "ALTERNATIVE: One-liner deployment"
echo "================================================"
echo ""
echo "If you prefer, save the base64 content to a file and use this shortened version:"
echo ""

# Generate a shorter version
B64_CONTENT=$(cat /tmp/portal-deploy.b64)
echo "cd /opt/employee-portal && echo '$B64_CONTENT' | base64 -d > portal-deploy.tar.gz && sudo tar -xzf portal-deploy.tar.gz && sudo chmod +x install.sh && sudo ./install.sh" | head -c 200
echo "..."
echo ""
echo "(Full command is too long to display, use the first method)"
echo ""
echo "================================================"
echo "After deployment, verify:"
echo "================================================"
echo ""
echo "1. Service running: sudo systemctl status employee-portal"
echo "2. Logs: sudo journalctl -u employee-portal -f"
echo "3. Local test: curl http://localhost:8000/"
echo "4. Web access: https://portal.capsule-playground.com"
echo "5. Login as: dmar@capsule.com / SecurePass123!"
echo "6. Check EC2 Resources tab (admin only)"
echo ""
