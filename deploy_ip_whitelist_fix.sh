#!/bin/bash
set -e

echo "================================================"
echo "Deploying IP Whitelisting Fix"
echo "================================================"

DEPLOY_DIR="/tmp/ip-whitelist-fix-$$"
mkdir -p "$DEPLOY_DIR"

cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5

# Extract app.py from user_data.sh
echo "Extracting application code..."
sed -n '/^cat > \/opt\/employee-portal\/app.py << EOFAPP/,/^EOFAPP$/p' user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/app.py"

# Verify extraction
if [ ! -s "$DEPLOY_DIR/app.py" ]; then
    echo "ERROR: app.py extraction failed!"
    exit 1
fi

echo "Extracted app.py: $(wc -l "$DEPLOY_DIR/app.py" | cut -d' ' -f1) lines"

# Substitute variables
USER_POOL_ID="us-west-2_WePThH2J8"
AWS_REGION="us-west-2"
CLIENT_ID="7qa8jhkle0n5hfqq2pa3ld30b"
CLIENT_SECRET="1cr0fa5s6d4j5n7i4fgl5ilndlo9cvgjsgd92mqgpb94d98o7ksl"

sed -i "s/\${user_pool_id}/$USER_POOL_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${aws_region}/$AWS_REGION/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_id}/$CLIENT_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_secret}/$CLIENT_SECRET/g" "$DEPLOY_DIR/app.py"

# Verify the fix is in the extracted code
echo "Verifying description format fix..."
if grep -q 'description = f"User={email}, IP={client_ip}' "$DEPLOY_DIR/app.py"; then
    echo "✓ Description format fix confirmed in extracted code"
else
    echo "ERROR: Description format fix not found in extracted code!"
    exit 1
fi

# Backup current app.py on portal server
echo "Backing up current app.py..."
TIMESTAMP=$(date +%s)
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  "sudo cp /opt/employee-portal/app.py /opt/employee-portal/app.py.backup.$TIMESTAMP"

# Deploy new app.py
echo "Deploying updated app.py..."
scp -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem "$DEPLOY_DIR/app.py" ubuntu@54.202.154.151:/tmp/

ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 << 'REMOTE'
sudo mv /tmp/app.py /opt/employee-portal/app.py
sudo chown app:app /opt/employee-portal/app.py
sudo systemctl restart employee-portal
sleep 3
sudo systemctl status employee-portal | head -15
REMOTE

echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo "Changes deployed:"
echo "  ✓ Fixed security group rule description (pipe → comma)"
echo "  ✓ Service restarted successfully"
echo ""
rm -rf "$DEPLOY_DIR"
echo "Ready for testing!"
