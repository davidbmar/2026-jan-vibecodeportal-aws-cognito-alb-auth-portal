#!/bin/bash
set -e

echo "================================================"
echo "Deploying Passwordless Update"
echo "================================================"

# Extract app.py from user_data.sh
echo "Extracting application code..."
DEPLOY_DIR="/tmp/passwordless-deploy-$$"
mkdir -p "$DEPLOY_DIR"

cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

sed -n '/^cat > \/opt\/employee-portal\/app.py << EOFAPP/,/^EOFAPP$/p' user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/app.py"

# Substitute variables
USER_POOL_ID="us-west-2_WePThH2J8"
AWS_REGION="us-west-2"
CLIENT_ID="7qa8jhkle0n5hfqq2pa3ld30b"
CLIENT_SECRET="1cr0fa5s6d4j5n7i4fgl5ilndlo9cvgjsgd92mqgpb94d98o7ksl"

sed -i "s/\${user_pool_id}/$USER_POOL_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${aws_region}/$AWS_REGION/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_id}/$CLIENT_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_secret}/$CLIENT_SECRET/g" "$DEPLOY_DIR/app.py"

# Verify extraction worked
if [ ! -s "$DEPLOY_DIR/app.py" ]; then
    echo "ERROR: app.py extraction failed - file is empty!"
    exit 1
fi

echo "Extracted app.py: $(wc -l "$DEPLOY_DIR/app.py" | cut -d' ' -f1) lines"

# Extract home.html template
echo "Extracting home template..."
sed -n "/^cat > \/opt\/employee-portal\/templates\/home.html << 'EOFHOME'/,/^EOFHOME$/p" user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/home.html"

if [ ! -s "$DEPLOY_DIR/home.html" ]; then
    echo "ERROR: home.html extraction failed - file is empty!"
    exit 1
fi

echo "Extracted home.html: $(wc -l "$DEPLOY_DIR/home.html" | cut -d' ' -f1) lines"

# Backup current files on server
echo "Backing up current files..."
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup.$(date +%s) 2>/dev/null || true'
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 'sudo cp /opt/employee-portal/templates/home.html /opt/employee-portal/templates/home.html.backup.$(date +%s) 2>/dev/null || true'

# Deploy files
echo "Deploying files..."
scp -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem "$DEPLOY_DIR/app.py" ubuntu@54.202.154.151:/tmp/
scp -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem "$DEPLOY_DIR/home.html" ubuntu@54.202.154.151:/tmp/

ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 << 'REMOTE'
sudo mv /tmp/app.py /opt/employee-portal/app.py
sudo mv /tmp/home.html /opt/employee-portal/templates/home.html
sudo chown app:app /opt/employee-portal/app.py /opt/employee-portal/templates/home.html
sudo systemctl restart employee-portal
sleep 3
sudo systemctl status employee-portal
REMOTE

echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo "Portal URL: https://portal.capsule-playground.com"
echo ""
echo "Changes deployed:"
echo "  ✓ Password field removed from user creation"
echo "  ✓ Auto-generated passwords enabled"
echo "  ✓ Password reset endpoints removed"
echo "  ✓ Password reset templates removed"
echo "  ✓ Settings link updated to MFA setup"
echo ""
echo "Cleanup temp files..."
rm -rf "$DEPLOY_DIR"
echo "Done!"
