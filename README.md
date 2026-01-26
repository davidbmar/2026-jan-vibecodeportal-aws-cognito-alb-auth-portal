# Employee Access Portal

A minimal MVP "Employee Access Portal" built on AWS using Cognito + ALB authentication + EC2. The ALB handles authentication using Cognito's authenticate-cognito action, and the application reads user identity from ALB headers and enforces group-based access control.

## Architecture

- **Cognito User Pool**: User authentication and group management
- **Application Load Balancer (ALB)**: Handles authentication via authenticate-cognito action
- **EC2 Instance**: Runs a minimal FastAPI application
- **VPC**: Isolated network with public subnets for ALB and EC2
- **IAM**: Instance role with permissions to query Cognito for group membership

## Features

- ALB-managed authentication (no OIDC implementation in app)
- Group-based authorization enforced by the application
- In-memory caching of group memberships (60s TTL)
- Simple UI showing user info, directory, and protected area pages
- Health check endpoint bypassing authentication

## Users and Groups

### Groups
- `engineering`
- `hr`
- `automation`
- `product`
- `admins`

### Seeded Users
- `dmar@capsule.com` → engineering, admins
- `jahn@capsule.com` → engineering
- `ahatcher@capsule.com` → hr
- `peter@capsule.com` → automation
- `sdedakia@capsule.com` → product

All users are created in `FORCE_CHANGE_PASSWORD` state and require password setup via AWS CLI.

## Routes

| Route | Auth Required | Description |
|-------|---------------|-------------|
| `/health` | No | Health check endpoint (200 OK) |
| `/` | Yes | Home page showing logged-in user, groups, and allowed areas |
| `/directory` | Yes | Shows hardcoded table of users and their assigned areas |
| `/areas/engineering` | Yes (engineering) | Engineering area page |
| `/areas/hr` | Yes (hr) | HR area page |
| `/areas/automation` | Yes (automation) | Automation area page |
| `/areas/product` | Yes (product) | Product area page |
| `/denied` | Yes | Access denied page |

## Prerequisites

- AWS CLI configured with credentials
- Terraform >= 1.0
- `jq` (for pretty output in deploy script)
- An AWS account with permissions to create VPC, EC2, ALB, Cognito, and IAM resources

## Project Structure

```
.
├── README.md
├── scripts/
│   └── deploy.sh              # Deployment script
├── terraform/
│   └── envs/
│       └── tier5/
│           ├── main.tf        # Main Terraform configuration
│           ├── variables.tf   # Input variables
│           ├── outputs.tf     # Output values
│           └── user_data.sh   # EC2 initialization script
└── app/                       # (Created by user_data.sh on EC2)
    ├── app.py                 # FastAPI application
    └── templates/             # Jinja2 templates
        ├── base.html
        ├── home.html
        ├── directory.html
        ├── area.html
        └── denied.html
```

## Deployment

### Step 1: Deploy Infrastructure

Run the deployment script:

```bash
./scripts/deploy.sh
```

This will:
1. Initialize Terraform
2. Create a plan
3. Apply the configuration
4. Output all necessary information

The deployment creates:
- VPC with 2 public subnets across 2 AZs
- Internet Gateway and Route Tables
- Security Groups (ALB allows HTTP from internet, EC2 allows traffic only from ALB)
- Cognito User Pool with domain, app client, groups, and users
- ALB with listener rules for health check bypass and authenticated routes
- EC2 instance (t3.micro) with IAM instance profile
- Target group with health checks on `/health`

### Step 2: Wait for EC2 Initialization

Wait 2-3 minutes for the EC2 instance to:
- Install Python and dependencies
- Create the FastAPI application
- Start the systemd service
- Become healthy in the target group

You can check the target group health in the AWS Console.

### Step 3: Set User Passwords

After deployment, set permanent passwords for the users. The deploy script outputs these commands, but here's the template:

```bash
# Get the User Pool ID from terraform output
USER_POOL_ID=$(cd terraform/envs/tier5 && terraform output -raw cognito_user_pool_id)

# Set password for dmar@capsule.com
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username dmar@capsule.com \
  --password "YourSecurePassword123!" \
  --permanent \
  --region us-east-1

# Set password for jahn@capsule.com
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username jahn@capsule.com \
  --password "YourSecurePassword123!" \
  --permanent \
  --region us-east-1

# Set password for ahatcher@capsule.com
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username ahatcher@capsule.com \
  --password "YourSecurePassword123!" \
  --permanent \
  --region us-east-1

# Set password for peter@capsule.com
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username peter@capsule.com \
  --password "YourSecurePassword123!" \
  --permanent \
  --region us-east-1

# Set password for sdedakia@capsule.com
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username sdedakia@capsule.com \
  --password "YourSecurePassword123!" \
  --permanent \
  --region us-east-1
```

**Note**: Replace `YourSecurePassword123!` with a secure password that meets the password policy requirements:
- Minimum 8 characters
- Contains uppercase letter
- Contains lowercase letter
- Contains number
- Contains symbol

### Step 4: Access the Portal

Get the ALB DNS name:

```bash
cd terraform/envs/tier5
terraform output -raw alb_dns_name
```

Access the portal at: `http://<alb-dns-name>/`

## Testing

### Test Authentication Flow

1. **Access the home page**:
   ```
   http://<alb-dns-name>/
   ```
   You'll be redirected to Cognito's hosted UI for login.

2. **Login with dmar@capsule.com**:
   - After login, you should see:
     - Email: dmar@capsule.com
     - Groups: engineering, admins
     - Allowed areas: Engineering

3. **Navigate to Engineering area**:
   ```
   http://<alb-dns-name>/areas/engineering
   ```
   - Access should be granted

4. **Try to access HR area**:
   ```
   http://<alb-dns-name>/areas/hr
   ```
   - You should be redirected to `/denied`

5. **Logout and login with ahatcher@capsule.com**:
   - Should see groups: hr
   - Can access `/areas/hr` only
   - Cannot access `/areas/engineering`

### Test Health Check (No Auth)

```bash
curl http://<alb-dns-name>/health
```

Should return:
```json
{"status":"ok","timestamp":"2026-01-24T..."}
```

This endpoint bypasses authentication and is used by the ALB health checks.

## How It Works

### ALB Authentication Flow

1. User accesses any route except `/health`
2. ALB intercepts the request
3. If not authenticated, ALB redirects to Cognito hosted UI
4. User logs in with Cognito
5. Cognito redirects back to ALB with auth code
6. ALB validates the auth code and sets cookies
7. ALB adds `x-amzn-oidc-data` header (JWT) to request
8. ALB forwards request to EC2 instance

### Application Authorization Flow

1. App extracts email from `x-amzn-oidc-data` JWT header
2. App queries Cognito for user's groups:
   ```python
   cognito_client.admin_list_groups_for_user(
       UserPoolId=USER_POOL_ID,
       Username=email
   )
   ```
3. App caches group membership for 60 seconds
4. For protected routes, app checks if user has required group
5. If authorized, shows the page; otherwise redirects to `/denied`

### IAM Permissions

The EC2 instance has an IAM role with minimal permissions:
- `cognito-idp:AdminListGroupsForUser` (scoped to the User Pool)
- `cognito-idp:AdminGetUser` (optional, scoped to the User Pool)

### Security

- ALB handles all authentication - app trusts ALB headers
- EC2 security group only allows traffic from ALB security group
- No direct internet access to EC2 instance on app port
- Deny-by-default authorization model
- Group membership cached for 60s to reduce Cognito API calls

## Configuration

### Change AWS Region

Edit `terraform/envs/tier5/variables.tf`:

```hcl
variable "aws_region" {
  default = "us-west-2"  # Change this
}
```

### Change Project Name

Edit `terraform/envs/tier5/variables.tf`:

```hcl
variable "project_name" {
  default = "my-portal"  # Change this
}
```

### Add More Users

Edit `terraform/envs/tier5/main.tf` and add resources:

```hcl
resource "aws_cognito_user" "newuser" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "newuser@capsule.com"

  attributes = {
    email          = "newuser@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "newuser_engineering" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.engineering.name
  username     = aws_cognito_user.newuser.username
}
```

### Update Directory Listing

The directory page shows a hardcoded list. To update, modify the `USER_REGISTRY` in the `user_data.sh` template:

```python
USER_REGISTRY = [
    {"email": "dmar@capsule.com", "areas": "engineering, admins"},
    {"email": "newuser@capsule.com", "areas": "engineering"},
    # Add more here
]
```

Then reapply Terraform to recreate the EC2 instance with the new user data.

## Troubleshooting

### EC2 Instance Not Healthy

Check the systemd service status:
```bash
# SSH to EC2 instance
sudo systemctl status employee-portal

# Check logs
sudo journalctl -u employee-portal -f
```

### Cannot Login

1. Verify passwords are set:
   ```bash
   aws cognito-idp admin-get-user \
     --user-pool-id <pool-id> \
     --username dmar@capsule.com
   ```
   Status should be `CONFIRMED` not `FORCE_CHANGE_PASSWORD`.

2. Check Cognito app client callback URLs match ALB DNS:
   ```bash
   cd terraform/envs/tier5
   terraform output alb_dns_name
   ```

### Access Denied for Valid Group

1. Check user's actual groups:
   ```bash
   aws cognito-idp admin-list-groups-for-user \
     --user-pool-id <pool-id> \
     --username dmar@capsule.com
   ```

2. Check app logs on EC2:
   ```bash
   sudo journalctl -u employee-portal -n 100
   ```

### Terraform Errors

If you get errors about existing resources, you may need to import or destroy:
```bash
cd terraform/envs/tier5
terraform destroy  # Start fresh
```

## Clean Up

To destroy all resources:

```bash
cd terraform/envs/tier5
terraform destroy
```

This will remove:
- EC2 instance
- ALB and target group
- Cognito User Pool (including all users and groups)
- VPC and all networking resources
- Security groups
- IAM roles and policies

## Costs

Estimated monthly costs for this MVP (us-east-1):
- EC2 t3.micro: ~$7.50
- ALB: ~$16.20 + data processing
- Cognito: Free tier (50,000 MAUs)
- Data transfer: Minimal for testing

**Total: ~$25-30/month**

## Defaults and Design Decisions

1. **Region**: us-east-1 (configurable via variable)
2. **VPC CIDR**: 10.0.0.0/16
3. **Instance Type**: t3.micro (eligible for free tier)
4. **Python Stack**: FastAPI + Uvicorn (fast, minimal dependencies)
5. **Cache TTL**: 60 seconds for group memberships
6. **ALB Protocol**: HTTP only (HTTPS requires ACM certificate)
7. **Authentication**: ALB-managed via Cognito (no app-side OIDC)
8. **Authorization**: App queries Cognito per-user (not listing all users)
9. **Deployment**: Single environment (tier5)

## Limitations (MVP)

- No HTTPS (would require domain + ACM certificate)
- No admin UI to manage users
- No pagination (not needed for small user set)
- No rate limiting
- No detailed audit logging
- Health check uses HTTP 200, not database connection check
- Single EC2 instance (no auto-scaling)
- Hardcoded directory list (not querying Cognito for all users)

## Extension Ideas

- Add HTTPS with ACM certificate and custom domain
- Add admin area for user management
- Add CloudWatch dashboards and alarms
- Add WAF rules for ALB
- Implement session timeout controls
- Add more sophisticated caching (Redis)
- Add database for user profiles/settings
- Implement auto-scaling for EC2

## License

MIT
