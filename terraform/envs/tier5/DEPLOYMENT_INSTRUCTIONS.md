# Portal Application Deployment Instructions

## Overview
The portal instance `i-05e5ad9868574ad07` is running in us-west-2 with dependencies installed, but the application code needs to be deployed. The deployment package has been created at `/tmp/portal-deploy.tar.gz` on the current instance.

## Deployment Package Contents
- **app.py**: Main FastAPI application with EC2 Resources feature
- **templates/**: All HTML templates including ec2_resources.html
- **employee-portal.service**: Systemd service configuration
- **install.sh**: Automated installation script

## Option 1: Deploy via AWS Console (Recommended)

### Step 1: Connect to Portal Instance
1. Open AWS Console → Systems Manager → Session Manager
2. Click "Start session"
3. Select instance: `i-05e5ad9868574ad07` (employee-portal-portal)
4. Click "Start session"

### Step 2: Transfer Deployment Package
Since the package is on another instance, run these commands in the Session Manager terminal:

```bash
# Download the deployment script and package from this gist
# (Alternative: Use S3 if you have a bucket with write permissions)

# Create deployment package inline
cd /opt/employee-portal
cat > portal-deploy.tar.gz.b64 << 'EOFB64'
```

Then paste the base64 content from `/tmp/portal-deploy.b64`, then:

```bash
EOFB64

base64 -d portal-deploy.tar.gz.b64 > portal-deploy.tar.gz
rm portal-deploy.tar.gz.b64
```

### Step 3: Extract and Install
```bash
cd /opt/employee-portal
sudo tar -xzf portal-deploy.tar.gz
sudo chmod +x install.sh
sudo ./install.sh
```

### Step 4: Verify Deployment
```bash
sudo systemctl status employee-portal
curl http://localhost:8000/
```

## Option 2: Deploy via SCP (If SSH access is configured)

```bash
# From the current instance
scp /tmp/portal-deploy.tar.gz ubuntu@16.148.199.21:/tmp/
ssh ubuntu@16.148.199.21 'cd /opt/employee-portal && sudo tar -xzf /tmp/portal-deploy.tar.gz && sudo ./install.sh'
```

## Option 3: Use Simplified Deployment Script

Run this script which uses AWS SSM to execute commands:

```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
./manual-deploy.sh i-05e5ad9868574ad07
```

## What the Installation Does

The `install.sh` script will:
1. Extract app.py and templates to /opt/employee-portal/
2. Set correct file permissions (app:app ownership)
3. Copy systemd service file to /etc/systemd/system/
4. Reload systemd daemon
5. Enable and start the employee-portal service
6. Verify the service is running on port 8000

## Post-Deployment Verification

### 1. Check Service Status
```bash
sudo systemctl status employee-portal
```

Expected output: Active (running)

### 2. Check Application Logs
```bash
sudo journalctl -u employee-portal -f
```

### 3. Test Local Access
```bash
curl http://localhost:8000/
```

Should return HTML content.

### 4. Test via ALB
Open browser: https://portal.capsule-playground.com

### 5. Test EC2 Resources Feature
1. Login as admin: dmar@capsule.com / SecurePass123!
2. Click "EC2 Resources" tab
3. Should see table with 3 tagged instances:
   - Engineering: i-0d1e3b59f57974076
   - HR: i-06883f2837f77f365
   - Product: i-0966d965518d2dba1
4. Click "Refresh" button to fetch live data
5. Click Engineering tab → should redirect to SSM Session Manager

## Troubleshooting

### Service won't start
```bash
sudo journalctl -u employee-portal -n 50
```

Common issues:
- Port 8000 already in use
- Python venv not activated
- Missing dependencies

### EC2 Resources page shows errors
Check IAM role permissions on portal instance:
```bash
aws sts get-caller-identity
aws ec2 describe-instances --max-results 1  # Test EC2 API access
```

### SSM redirect doesn't work
Verify the tagged instances exist in us-west-2:
```bash
aws ec2 describe-instances \
  --region us-west-2 \
  --filters "Name=tag:VibeCodeArea,Values=*" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`VibeCodeArea`].Value|[0]]' \
  --output table
```

## Application Configuration

The application automatically configures itself using:
- **User Pool ID**: Retrieved from user_data.sh (`USER_POOL_ID = "us-west-2_WePThH2J8"`)
- **AWS Region**: `us-west-2`
- **ALB Headers**: X-Amzn-Oidc-Data, X-Amzn-Oidc-Accesstoken

No manual configuration required.

## Files Deployed

```
/opt/employee-portal/
├── app.py                          # Main FastAPI application
├── templates/
│   ├── base.html                   # Base template with navigation
│   ├── home.html                   # Home page
│   ├── directory.html              # User directory
│   ├── area.html                   # Area pages (Engineering/HR/Product)
│   ├── ec2_resources.html          # NEW: EC2 Resources management page
│   ├── denied.html                 # Access denied page
│   └── error.html                  # Error page
├── employee-portal.service         # Systemd service configuration
└── venv/                           # Python virtual environment

/etc/systemd/system/
└── employee-portal.service         # Systemd service (symlink)
```

## Manual Deployment Alternative

If automated deployment fails, you can manually deploy:

1. **Copy app.py**:
```bash
sudo nano /opt/employee-portal/app.py
# Paste content from user_data.sh between app.py markers
```

2. **Create templates**:
```bash
sudo mkdir -p /opt/employee-portal/templates
# For each template, copy content from user_data.sh
```

3. **Create service file**:
```bash
sudo nano /etc/systemd/system/employee-portal.service
```

Paste:
```ini
[Unit]
Description=Employee Portal
After=network.target

[Service]
Type=simple
User=app
WorkingDirectory=/opt/employee-portal
Environment="PATH=/opt/employee-portal/venv/bin"
ExecStart=/opt/employee-portal/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

4. **Start service**:
```bash
sudo systemctl daemon-reload
sudo systemctl enable employee-portal
sudo systemctl start employee-portal
```

## Support

Portal Instance Details:
- **Instance ID**: i-05e5ad9868574ad07
- **Private IP**: 10.0.1.227
- **Public IP**: 16.148.199.21
- **Region**: us-west-2
- **User Pool ID**: us-west-2_WePThH2J8

For issues, check:
1. Instance IAM role has EC2 API permissions
2. Security group allows ALB traffic
3. User Pool ID is correct in app.py
4. SSM Agent is running: `sudo systemctl status amazon-ssm-agent`
