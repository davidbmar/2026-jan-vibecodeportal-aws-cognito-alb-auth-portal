# Quick Start Guide

## Deploy in 3 Steps

### 1. Deploy Infrastructure
```bash
./scripts/deploy.sh
```

Wait 2-3 minutes for EC2 to initialize.

### 2. Set User Passwords

```bash
# Get User Pool ID
cd terraform/envs/tier5
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id)

# Set passwords for all users (replace YOUR_PASSWORD with a secure password)
for USER in dmar@capsule.com jahn@capsule.com ahatcher@capsule.com peter@capsule.com sdedakia@capsule.com; do
  aws cognito-idp admin-set-user-password \
    --user-pool-id $USER_POOL_ID \
    --username $USER \
    --password "SecurePass123!" \
    --permanent \
    --region us-east-1
done
```

### 3. Access the Portal

```bash
# Get ALB URL
ALB_URL=$(terraform output -raw alb_dns_name)
echo "Portal URL: http://$ALB_URL/"

# Open in browser
echo "http://$ALB_URL/"
```

## Test Users

| Email | Password | Groups | Can Access |
|-------|----------|--------|------------|
| dmar@capsule.com | (set above) | engineering, admins | /areas/engineering |
| jahn@capsule.com | (set above) | engineering | /areas/engineering |
| ahatcher@capsule.com | (set above) | hr | /areas/hr |
| peter@capsule.com | (set above) | automation | /areas/automation |
| sdedakia@capsule.com | (set above) | product | /areas/product |

## Key URLs

- Home: `http://<alb-dns>/`
- Directory: `http://<alb-dns>/directory`
- Engineering: `http://<alb-dns>/areas/engineering`
- HR: `http://<alb-dns>/areas/hr`
- Automation: `http://<alb-dns>/areas/automation`
- Product: `http://<alb-dns>/areas/product`
- Health: `http://<alb-dns>/health` (no auth)

## Clean Up

```bash
cd terraform/envs/tier5
terraform destroy
```

## Troubleshooting

### Check EC2 service status
```bash
# Get EC2 instance ID
INSTANCE_ID=$(cd terraform/envs/tier5 && terraform output -json | jq -r '.ec2_instance_id.value // empty')

# If you have SSM access:
aws ssm start-session --target $INSTANCE_ID

# Then check service:
sudo systemctl status employee-portal
sudo journalctl -u employee-portal -f
```

### Check user status
```bash
aws cognito-idp admin-get-user \
  --user-pool-id $USER_POOL_ID \
  --username dmar@capsule.com
```

### View all outputs
```bash
cd terraform/envs/tier5
terraform output
```
