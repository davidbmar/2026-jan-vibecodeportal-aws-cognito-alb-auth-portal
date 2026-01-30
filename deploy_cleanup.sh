#!/bin/bash
set -e

echo "================================================"
echo "Deploying Cleanup Update (Remove MFA Button)"
echo "================================================"

DEPLOY_DIR="/tmp/cleanup-deploy-$$"
mkdir -p "$DEPLOY_DIR"

cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Extract home.html template
echo "Extracting home template..."
sed -n "/^cat > \/opt\/employee-portal\/templates\/home.html << 'EOFHOME'/,/^EOFHOME$/p" user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/home.html"

if [ ! -s "$DEPLOY_DIR/home.html" ]; then
    echo "ERROR: home.html extraction failed!"
    exit 1
fi

echo "Extracted home.html: $(wc -l "$DEPLOY_DIR/home.html" | cut -d' ' -f1) lines"

# Deploy file
echo "Deploying updated home template..."
scp -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem "$DEPLOY_DIR/home.html" ubuntu@54.202.154.151:/tmp/

ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 << 'REMOTE'
sudo mv /tmp/home.html /opt/employee-portal/templates/home.html
sudo chown app:app /opt/employee-portal/templates/home.html
sudo systemctl restart employee-portal
sleep 3
sudo systemctl status employee-portal | head -15
REMOTE

echo ""
echo "================================================"
echo "Cleanup Complete!"
echo "================================================"
echo "Changes:"
echo "  ✓ Removed MFA Setup button (non-existent functionality)"
echo "  ✓ Updated deploy-portal.sh template list"
echo "  ✓ Simplified home page messaging"
echo ""
rm -rf "$DEPLOY_DIR"
echo "Done!"
