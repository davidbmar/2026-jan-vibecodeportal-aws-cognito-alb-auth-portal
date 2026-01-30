#!/bin/bash
set -e

# Deploy Employee Portal Application to EC2 Instance
# Usage: ./deploy-portal.sh <instance-id>

if [ -z "$1" ]; then
    echo "Usage: $0 <instance-id>"
    echo "Example: $0 i-0123456789abcdef0"
    exit 1
fi

INSTANCE_ID=$1
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "us-east-1_XXXXXXX")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
CLIENT_ID=$(terraform output -raw cognito_app_client_id 2>/dev/null || echo "")
CLIENT_SECRET=$(terraform output -raw cognito_app_client_secret 2>/dev/null || echo "")

echo "================================================"
echo "Employee Portal Deployment Script"
echo "================================================"
echo "Target Instance: $INSTANCE_ID"
echo "User Pool ID: $USER_POOL_ID"
echo "AWS Region: $AWS_REGION"
echo ""

# Check if instance exists and is running
echo "Checking instance status..."
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")

if [ "$INSTANCE_STATE" != "running" ]; then
    echo "ERROR: Instance $INSTANCE_ID is not running (state: $INSTANCE_STATE)"
    exit 1
fi

echo "Instance is running. Getting connection details..."

# Get instance IP
INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "Instance Private IP: $INSTANCE_IP"

# Create deployment package
echo ""
echo "Creating deployment package..."
DEPLOY_DIR="/tmp/portal-deploy-$$"
mkdir -p "$DEPLOY_DIR/templates"

# Extract app.py from user_data.sh
echo "Extracting application code..."
sed -n '/^cat > \/opt\/employee-portal\/app.py << .EOFAPP./,/^EOFAPP$/p' user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/app.py"

# Substitute variables
sed -i "s/\${user_pool_id}/$USER_POOL_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${aws_region}/$AWS_REGION/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_id}/$CLIENT_ID/g" "$DEPLOY_DIR/app.py"
sed -i "s/\${client_secret}/$CLIENT_SECRET/g" "$DEPLOY_DIR/app.py"

# Extract templates
echo "Extracting templates..."
for template in base.html home.html directory.html area.html denied.html logged_out.html login.html error.html admin_panel.html ec2_resources.html; do
    template_upper=$(echo $template | sed 's/\.html//' | tr 'a-z' 'A-Z' | tr '-' '_')
    marker="EOF${template_upper}"
    if grep -q "EOF${template_upper}" user_data.sh 2>/dev/null; then
        sed -n "/^cat > \/opt\/employee-portal\/templates\/${template} << '${marker}'/,/^${marker}$/p" user_data.sh | sed '1d;$d' > "$DEPLOY_DIR/templates/$template"
        echo "  - Extracted $template"
    fi
done

# Create systemd service file
echo "Creating systemd service configuration..."
cat > "$DEPLOY_DIR/employee-portal.service" << 'EOFSVC'
[Unit]
Description=Employee Portal FastAPI Application
After=network.target

[Service]
Type=simple
User=app
WorkingDirectory=/opt/employee-portal
Environment="PATH=/opt/employee-portal/venv/bin"
ExecStart=/opt/employee-portal/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSVC

# Create deployment script to run on the instance
cat > "$DEPLOY_DIR/install.sh" << 'EOFINSTALL'
#!/bin/bash
set -e

echo "Installing Employee Portal..."

# Wait for bootstrap to complete
while [ ! -f /tmp/bootstrap-complete ]; do
    echo "Waiting for bootstrap to complete..."
    sleep 5
done

# Copy files
sudo cp app.py /opt/employee-portal/
sudo cp -r templates /opt/employee-portal/
sudo cp employee-portal.service /etc/systemd/system/

# Set ownership
sudo chown -R app:app /opt/employee-portal

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable employee-portal
sudo systemctl restart employee-portal

# Check status
sleep 3
sudo systemctl status employee-portal --no-pager

echo ""
echo "Deployment complete!"
echo "Portal should be accessible at port 8000"
EOFINSTALL

chmod +x "$DEPLOY_DIR/install.sh"

# Create tarball
echo ""
echo "Creating deployment tarball..."
cd "$DEPLOY_DIR"
tar -czf /tmp/portal-deploy.tar.gz .
cd - > /dev/null

echo "Deployment package created: /tmp/portal-deploy.tar.gz"
echo ""
echo "================================================"
echo "Deploying to instance via SSM..."
echo "================================================"

# Copy files using SSM
echo "Uploading deployment package..."
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "mkdir -p /tmp/portal-deploy",
        "cd /tmp/portal-deploy"
    ]' \
    --output text \
    --query 'Command.CommandId' > /tmp/command-id.txt

sleep 3

# Upload tarball via S3 (requires S3 bucket) or direct copy
echo ""
echo "================================================"
echo "Manual Deployment Required"
echo "================================================"
echo ""
echo "The deployment package is ready at: /tmp/portal-deploy.tar.gz"
echo ""
echo "To complete deployment, run these commands:"
echo ""
echo "1. Copy the package to the instance:"
echo "   scp -i YOUR_KEY.pem /tmp/portal-deploy.tar.gz ubuntu@$INSTANCE_IP:/tmp/"
echo ""
echo "2. SSH into the instance:"
echo "   ssh -i YOUR_KEY.pem ubuntu@$INSTANCE_IP"
echo ""
echo "3. Extract and install:"
echo "   cd /tmp && tar -xzf portal-deploy.tar.gz && sudo bash install.sh"
echo ""
echo "================================================"

# Cleanup
rm -rf "$DEPLOY_DIR"

echo ""
echo "Deployment script completed!"
