#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y python3-pip python3-venv git

# Create app directory
mkdir -p /opt/employee-portal
cd /opt/employee-portal

# Create app user
useradd -r -s /bin/bash app || true

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install fastapi uvicorn[standard] python-jose[cryptography] boto3 jinja2 python-multipart

# Create app.py
cat > /opt/employee-portal/app.py << EOFAPP
import os
import json
import base64
import time
import re
import hmac
import hashlib
from typing import Optional
from datetime import datetime, timedelta
import io
import boto3
from fastapi import FastAPI, Request, HTTPException, Form, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from jose import jwt, JWTError

app = FastAPI()
templates = Jinja2Templates(directory="/opt/employee-portal/templates")

# Configuration
USER_POOL_ID = "${user_pool_id}"
AWS_REGION = "${aws_region}"
CLIENT_ID = "${client_id}"
CLIENT_SECRET = "${client_secret}"

# Cognito client
cognito_client = boto3.client('cognito-idp', region_name=AWS_REGION)

def get_secret_hash(username: str) -> str:
    """Calculate SECRET_HASH for Cognito client with secret."""
    message = bytes(username + CLIENT_ID, 'utf-8')
    secret = bytes(CLIENT_SECRET, 'utf-8')
    dig = hmac.new(secret, message, hashlib.sha256).digest()
    return base64.b64encode(dig).decode()

# EC2 client
ec2_client = boto3.client('ec2', region_name=AWS_REGION)

# In-memory cache for group memberships
group_cache = {}
CACHE_TTL = 60  # seconds

# In-memory storage for MFA secrets (in production, use database)
# Format: {email: {"secret": "...", "verified": False}}
# mfa_secrets = {} # TOTP MFA - replaced with email MFA via Cognito

# Hardcoded user registry for directory page
USER_REGISTRY = [
    {"email": "dmar@capsule.com", "areas": "engineering, admins"},
    {"email": "jahn@capsule.com", "areas": "engineering"},
    {"email": "ahatcher@capsule.com", "areas": "hr"},
    {"email": "peter@capsule.com", "areas": "automation"},
    {"email": "sdedakia@capsule.com", "areas": "product"},
]

def extract_user_from_alb_header(request: Request) -> Optional[str]:
    """Extract user email from ALB x-amzn-oidc-data JWT header."""
    jwt_token = request.headers.get("x-amzn-oidc-data")
    if not jwt_token:
        return None

    try:
        # Decode without verification (ALB already verified it)
        # Split JWT and decode payload
        parts = jwt_token.split('.')
        if len(parts) != 3:
            return None

        # Decode payload (add padding if needed)
        payload = parts[1]
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += '=' * padding

        decoded = base64.urlsafe_b64decode(payload)
        claims = json.loads(decoded)

        # Try to get email from claims
        email = claims.get('email') or claims.get('cognito:username')
        return email
    except Exception as e:
        print(f"Error extracting user from JWT: {e}")
        return None

def get_user_groups(username: str) -> list:
    """Get groups for a user from Cognito, with caching."""
    cache_key = username
    now = time.time()

    # Check cache
    if cache_key in group_cache:
        cached_data, cached_time = group_cache[cache_key]
        if now - cached_time < CACHE_TTL:
            return cached_data

    # Fetch from Cognito
    try:
        response = cognito_client.admin_list_groups_for_user(
            UserPoolId=USER_POOL_ID,
            Username=username
        )
        groups = [g['GroupName'] for g in response.get('Groups', [])]

        # Cache the result
        group_cache[cache_key] = (groups, now)

        return groups
    except Exception as e:
        print(f"Error fetching groups for {username}: {e}")
        return []

def require_auth(request: Request) -> tuple:
    """Get authenticated user email and groups from request state (set by middleware)."""
    email = getattr(request.state, 'email', None)
    groups = getattr(request.state, 'groups', [])

    if not email:
        raise HTTPException(status_code=401, detail="Not authenticated")

    return email, groups

def require_group(request: Request, required_group: str) -> tuple:
    """Require a specific group membership."""
    email, groups = require_auth(request)

    if required_group not in groups:
        return None, None  # Will redirect to denied page

    return email, groups

# EC2 Management Functions
def get_instances_by_tag(tag_key: str = "VibeCodeArea", tag_value: Optional[str] = None) -> list:
    """Query EC2 instances with specified tag. If tag_value is None, returns all instances with the tag."""
    try:
        filters = [{'Name': f'tag:{tag_key}', 'Values': ['*']}]
        if tag_value:
            filters = [{'Name': f'tag:{tag_key}', 'Values': [tag_value]}]

        response = ec2_client.describe_instances(Filters=filters)

        instances = []
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                # Extract instance details
                instance_data = {
                    'instance_id': instance['InstanceId'],
                    'instance_type': instance['InstanceType'],
                    'state': instance['State']['Name'],
                    'private_ip': instance.get('PrivateIpAddress', 'N/A'),
                    'public_ip': instance.get('PublicIpAddress', 'N/A'),
                    'name': 'N/A',
                    'area': 'N/A'
                }

                # Extract Name and VibeCodeArea tags
                for tag in instance.get('Tags', []):
                    if tag['Key'] == 'Name':
                        instance_data['name'] = tag['Value']
                    elif tag['Key'] == tag_key:
                        instance_data['area'] = tag['Value']

                instances.append(instance_data)

        return instances
    except Exception as e:
        print(f"Error fetching EC2 instances: {e}")
        return []

def get_instance_by_area(area: str) -> Optional[dict]:
    """Get the EC2 instance mapped to a specific area."""
    instances = get_instances_by_tag(tag_value=area)
    if instances and len(instances) > 0:
        return instances[0]  # Return first matching instance
    return None

def validate_instance_exists(instance_id: str) -> bool:
    """Check if an EC2 instance exists and is accessible."""
    try:
        response = ec2_client.describe_instances(InstanceIds=[instance_id])
        return len(response['Reservations']) > 0
    except Exception as e:
        print(f"Error validating instance {instance_id}: {e}")
        return False

def tag_instance(instance_id: str, area: str) -> tuple:
    """Apply VibeCodeArea tag to an EC2 instance. Returns (success: bool, message: str)."""
    # Validate area value
    valid_areas = ['engineering', 'hr', 'automation', 'product']
    if area not in valid_areas:
        return False, f"Invalid area. Must be one of: {', '.join(valid_areas)}"

    # Validate instance exists
    if not validate_instance_exists(instance_id):
        return False, f"Instance {instance_id} not found or not accessible"

    try:
        ec2_client.create_tags(
            Resources=[instance_id],
            Tags=[{'Key': 'VibeCodeArea', 'Value': area}]
        )
        return True, f"Successfully tagged {instance_id} with area={area}"
    except Exception as e:
        return False, f"Error tagging instance: {str(e)}"

def build_ssm_url(instance_id: str) -> str:
    """Generate AWS Systems Manager Session Manager URL for an instance."""
    return f"https://console.aws.amazon.com/systems-manager/session-manager/{instance_id}?region={AWS_REGION}"

# User Management Functions
def list_cognito_users() -> list:
    """List all users from Cognito user pool with their groups and last login."""
    try:
        users = []
        paginator = cognito_client.get_paginator('list_users')

        for page in paginator.paginate(UserPoolId=USER_POOL_ID):
            for user in page['Users']:
                email = next((attr['Value'] for attr in user['Attributes'] if attr['Name'] == 'email'), 'N/A')

                # Get user's groups
                groups = get_user_groups(user['Username'])

                # Get last login from auth events
                last_login = 'Never'
                try:
                    auth_events = cognito_client.admin_list_user_auth_events(
                        UserPoolId=USER_POOL_ID,
                        Username=user['Username'],
                        MaxResults=1
                    )
                    if auth_events.get('AuthEvents'):
                        event = auth_events['AuthEvents'][0]
                        if event['EventType'] == 'SignIn' and event['EventResponse'] == 'Pass':
                            last_login = event['CreationDate'].strftime('%Y-%m-%d %H:%M UTC')
                except Exception as e:
                    # If auth events not available, use UserLastModifiedDate
                    if 'UserLastModifiedDate' in user:
                        last_login = user['UserLastModifiedDate'].strftime('%Y-%m-%d %H:%M UTC')

                users.append({
                    'username': user['Username'],
                    'email': email,
                    'status': user['UserStatus'],
                    'enabled': user['Enabled'],
                    'groups': ', '.join(groups) if groups else 'none',
                    'last_login': last_login
                })

        return users
    except Exception as e:
        print(f"Error listing Cognito users: {e}")
        return []

def create_cognito_user(email: str, groups: list = None) -> tuple:
    """Create a new user in Cognito and optionally add to groups. Returns (success: bool, message: str)."""
    try:
        # Generate a temporary password (user will be prompted to change on first login)
        import secrets
        import string
        temp_password = ''.join(secrets.choice(string.ascii_letters + string.digits + '!@#$%') for _ in range(12))
        temp_password = temp_password[:10] + 'Aa1!' + temp_password[10:]  # Ensure complexity

        # Create user with email - SUPPRESS email to prevent temporary password notification
        cognito_client.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=email,
            UserAttributes=[
                {'Name': 'email', 'Value': email},
                {'Name': 'email_verified', 'Value': 'true'}
            ],
            TemporaryPassword=temp_password,
            MessageAction='SUPPRESS'  # Don't send email - this is passwordless auth with email MFA
        )

        # Add user to groups if specified
        if groups:
            for group in groups:
                try:
                    cognito_client.admin_add_user_to_group(
                        UserPoolId=USER_POOL_ID,
                        Username=email,
                        GroupName=group
                    )
                except Exception as e:
                    print(f"Error adding user to group {group}: {e}")

        return True, f"User {email} created successfully. User can sign in with passwordless email verification."
    except Exception as e:
        return False, f"Error creating user: {str(e)}"

def delete_cognito_user(email: str) -> tuple:
    """Delete a user from Cognito. Returns (success: bool, message: str)."""
    try:
        cognito_client.admin_delete_user(
            UserPoolId=USER_POOL_ID,
            Username=email
        )
        return True, f"User {email} deleted successfully."
    except Exception as e:
        return False, f"Error deleting user: {str(e)}"

def validate_token(token: str) -> dict:
    """Validate JWT token from cookie."""
    try:
        # Decode without verification (Cognito signed it, we trust it)
        payload = jwt.decode(
            token,
            options={"verify_signature": False}
        )
        return payload
    except JWTError as e:
        print(f"JWT decode error: {e}")
        return None

@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    """Authentication middleware - checks JWT token in cookie."""
    # Public paths - no auth required
    public_paths = ["/login", "/verify-code", "/health", "/logged-out"]

    if request.url.path in public_paths:
        response = await call_next(request)
        return response

    # Check for auth cookie
    token = request.cookies.get("auth_token")
    if not token:
        return RedirectResponse(url="/login", status_code=302)

    # Validate token
    user_data = validate_token(token)
    if not user_data:
        return RedirectResponse(url="/login", status_code=302)

    # Attach user data to request state
    request.state.user = user_data
    request.state.email = user_data.get('email')
    request.state.groups = user_data.get('cognito:groups', [])

    response = await call_next(request)
    return response

@app.get("/health")
async def health():
    """Health check endpoint (no auth required)."""
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}

@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    """Display passwordless login page (no auth required)."""
    return templates.TemplateResponse("login.html", {
        "request": request,
        "step": "email"
    })

@app.post("/login", response_class=HTMLResponse)
async def login_submit(request: Request, email: str = Form(...)):
    """Handle login form submission - initiate passwordless custom auth."""
    try:
        response = cognito_client.initiate_auth(
            AuthFlow='CUSTOM_AUTH',
            ClientId=CLIENT_ID,
            AuthParameters={
                'USERNAME': email,
                'SECRET_HASH': get_secret_hash(email)
            }
        )

        # Lambda sends email automatically
        session_data = response['Session']

        return templates.TemplateResponse("login.html", {
            "request": request,
            "step": "code",
            "email": email,
            "session": session_data
        })

    except Exception as e:
        print(f"Login error: {e}")
        return templates.TemplateResponse("login.html", {
            "request": request,
            "step": "email",
            "error": "Invalid email address or user not found"
        })

@app.post("/verify-code", response_class=HTMLResponse)
async def verify_code(
    request: Request,
    code: str = Form(...),
    session: str = Form(...),
    email: str = Form(...)
):
    """Handle verification code submission."""
    try:
        auth_response = cognito_client.respond_to_auth_challenge(
            ClientId=CLIENT_ID,
            ChallengeName='CUSTOM_CHALLENGE',
            Session=session,
            ChallengeResponses={
                'ANSWER': code,
                'USERNAME': email,
                'SECRET_HASH': get_secret_hash(email)
            }
        )

        # Success - got tokens
        id_token = auth_response['AuthenticationResult']['IdToken']

        # Create response and set secure cookie
        response = RedirectResponse(url="/", status_code=303)
        response.set_cookie(
            key="auth_token",
            value=id_token,
            httponly=True,
            secure=True,
            samesite="lax",
            max_age=3600
        )

        return response

    except Exception as e:
        print(f"Verification error: {e}")
        return templates.TemplateResponse("login.html", {
            "request": request,
            "step": "code",
            "email": email,
            "session": session,
            "error": "Invalid code. Please try again."
        })

@app.get("/logout")
async def logout():
    """Logout endpoint that clears auth cookie."""
    response = RedirectResponse(url="/logged-out", status_code=302)
    response.delete_cookie("auth_token")
    return response

@app.get("/logout-and-reset")
async def logout_and_reset():
    """Redirect to password reset page.

    Note: We don't explicitly logout here because the password reset flow
    already provides security via email verification. Going through Cognito
    logout can cause OAuth redirect_uri errors.
    """
    return RedirectResponse(url="/password-reset", status_code=302)

@app.get("/logged-out", response_class=HTMLResponse)
async def logged_out(request: Request):
    """Logged out confirmation page (no auth required)."""
    response = templates.TemplateResponse("logged_out.html", {
        "request": request
    })

    # Clear all ALB authentication cookies aggressively
    cookie_names = [
        "AWSELBAuthSessionCookie",
        "AWSELBAuthSessionCookie-0",
        "AWSELBAuthSessionCookie-1",
        "AWSELBAuthSessionCookie-2"
    ]

    for cookie_name in cookie_names:
        # Delete with various domain combinations and all security attributes
        # Domain variations
        for domain in ["portal.capsule-playground.com", ".capsule-playground.com", ".portal.capsule-playground.com", None]:
            # Try with and without domain
            if domain:
                response.set_cookie(
                    key=cookie_name,
                    value="",
                    max_age=0,
                    expires=0,
                    path="/",
                    domain=domain,
                    secure=True,
                    httponly=True,
                    samesite="lax"
                )
            else:
                response.set_cookie(
                    key=cookie_name,
                    value="",
                    max_age=0,
                    expires=0,
                    path="/",
                    secure=True,
                    httponly=True,
                    samesite="lax"
                )

    # Prevent caching
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"

    return response

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Home page showing logged-in user info."""
    email, groups = require_auth(request)

    # Determine allowed areas based on groups
    allowed_areas = []
    area_map = {
        "engineering": "/areas/engineering",
        "hr": "/areas/hr",
        "automation": "/areas/automation",
        "product": "/areas/product"
    }

    for group in groups:
        if group in area_map:
            allowed_areas.append({"name": group.title(), "url": area_map[group]})

    return templates.TemplateResponse("home.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "allowed_areas": allowed_areas
    })

@app.get("/directory", response_class=HTMLResponse)
async def directory(request: Request):
    """Directory page showing all Cognito users."""
    email, groups = require_auth(request)

    # Fetch users from Cognito
    cognito_users = list_cognito_users()

    return templates.TemplateResponse("directory.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "users": cognito_users,
        "is_admin": 'admins' in groups
    })

@app.get("/areas/engineering", response_class=HTMLResponse)
async def area_engineering(request: Request):
    """Engineering area page - redirects to SSM if instance is mapped."""
    email, groups = require_group(request, "engineering")

    if not email:
        return RedirectResponse(url="/denied")

    # Check for mapped EC2 instance
    instance = get_instance_by_area("engineering")
    if instance and instance['state'] == 'running':
        ssm_url = build_ssm_url(instance['instance_id'])
        return RedirectResponse(url=ssm_url, status_code=302)
    elif instance and instance['state'] != 'running':
        # Instance exists but not running
        return templates.TemplateResponse("area.html", {
            "request": request,
            "email": email,
            "groups": groups,
            "area_name": "Engineering",
            "area_description": f"EC2 instance is {instance['state']}. Please start it first or contact your administrator."
        })

    # No mapped instance - show static page
    return templates.TemplateResponse("area.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "area_name": "Engineering",
        "area_description": "Welcome to the Engineering area. Access to technical resources and documentation."
    })

@app.get("/areas/hr", response_class=HTMLResponse)
async def area_hr(request: Request):
    """HR area page - redirects to SSM if instance is mapped."""
    email, groups = require_group(request, "hr")

    if not email:
        return RedirectResponse(url="/denied")

    # Check for mapped EC2 instance
    instance = get_instance_by_area("hr")
    if instance and instance['state'] == 'running':
        ssm_url = build_ssm_url(instance['instance_id'])
        return RedirectResponse(url=ssm_url, status_code=302)
    elif instance and instance['state'] != 'running':
        # Instance exists but not running
        return templates.TemplateResponse("area.html", {
            "request": request,
            "email": email,
            "groups": groups,
            "area_name": "Human Resources",
            "area_description": f"EC2 instance is {instance['state']}. Please start it first or contact your administrator."
        })

    # No mapped instance - show static page
    return templates.TemplateResponse("area.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "area_name": "Human Resources",
        "area_description": "Welcome to the HR area. Access to employee resources and policies."
    })

@app.get("/areas/automation", response_class=HTMLResponse)
async def area_automation(request: Request):
    """Automation area page."""
    email, groups = require_group(request, "automation")

    if not email:
        return RedirectResponse(url="/denied")

    return templates.TemplateResponse("area.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "area_name": "Automation",
        "area_description": "Welcome to the Automation area. Access to automation tools and scripts."
    })

@app.get("/areas/product", response_class=HTMLResponse)
async def area_product(request: Request):
    """Product area page - redirects to SSM if instance is mapped."""
    email, groups = require_group(request, "product")

    if not email:
        return RedirectResponse(url="/denied")

    # Check for mapped EC2 instance
    instance = get_instance_by_area("product")
    if instance and instance['state'] == 'running':
        ssm_url = build_ssm_url(instance['instance_id'])
        return RedirectResponse(url=ssm_url, status_code=302)
    elif instance and instance['state'] != 'running':
        # Instance exists but not running
        return templates.TemplateResponse("area.html", {
            "request": request,
            "email": email,
            "groups": groups,
            "area_name": "Product",
            "area_description": f"EC2 instance is {instance['state']}. Please start it first or contact your administrator."
        })

    # No mapped instance - show static page
    return templates.TemplateResponse("area.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "area_name": "Product",
        "area_description": "Welcome to the Product area. Access to product roadmaps and specifications."
    })

@app.get("/denied", response_class=HTMLResponse)
async def denied(request: Request):
    """Access denied page."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("denied.html", {
        "request": request,
        "email": email,
        "groups": groups
    })

@app.get("/mfa-setup", response_class=HTMLResponse)
async def mfa_setup_page(request: Request):
    """MFA setup page - shows QR code for TOTP MFA setup."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("mfa_setup.html", {
        "request": request,
        "email": email,
        "groups": groups
    })

# @app.get("/api/mfa/init")
# async def initialize_mfa(request: Request):
#     """Initialize MFA setup - generate TOTP secret and QR code."""
#     email, groups = require_auth(request)
# 
#     # Generate a new TOTP secret
#     secret = pyotp.random_base32()
# 
#     # Store the secret temporarily (not verified yet)
#     mfa_secrets[email] = {
#         "secret": secret,
#         "verified": False
#     }
# 
#     # Create TOTP URI for QR code
#     totp = pyotp.TOTP(secret)
#     provisioning_uri = totp.provisioning_uri(
#         name=email,
#         issuer_name="CAPSULE Portal"
#     )
# 
#     # Generate QR code as base64 image
#     qr = qrcode.QRCode(version=1, box_size=10, border=5)
#     qr.add_data(provisioning_uri)
#     qr.make(fit=True)
# 
#     img = qr.make_image(fill_color="black", back_color="white")
# 
#     # Convert to base64
#     buffer = io.BytesIO()
#     img.save(buffer, format='PNG')
#     buffer.seek(0)
#     qr_base64 = base64.b64encode(buffer.getvalue()).decode()
# 
#     return JSONResponse({
#         "success": True,
#         "secret": secret,
#         "qr_code": f"data:image/png;base64,{qr_base64}",
#         "provisioning_uri": provisioning_uri
#     })
# 
# @app.post("/api/mfa/verify")
# async def verify_mfa_code(request: Request):
#     """Verify the TOTP code entered by the user."""
#     email, groups = require_auth(request)
# 
#     # Get the verification code from request body
#     try:
#         body = await request.json()
#         code = body.get("code", "").strip()
#     except Exception:
#         raise HTTPException(status_code=400, detail="Invalid request body")
# 
#     if not code or len(code) != 6:
#         return JSONResponse({
#             "success": False,
#             "error": "Please enter a 6-digit code"
#         }, status_code=400)
# 
#     # Check if user has initiated MFA setup
#     if email not in mfa_secrets:
#         return JSONResponse({
#             "success": False,
#             "error": "MFA setup not initialized. Please refresh and try again."
#         }, status_code=400)
# 
#     secret = mfa_secrets[email]["secret"]
# 
#     # Verify the code
#     totp = pyotp.TOTP(secret)
#     is_valid = totp.verify(code, valid_window=1)  # Allow 1 time step window
# 
#     if is_valid:
#         # Mark as verified
#         mfa_secrets[email]["verified"] = True
# 
#         return JSONResponse({
#             "success": True,
#             "message": "MFA successfully configured!"
#         })
#     else:
#         return JSONResponse({
#             "success": False,
#             "error": "Invalid code. Please check your authenticator app and try again."
#         }, status_code=400)
# 
# @app.get("/api/mfa/status")
# async def get_mfa_status(request: Request):
#     """Check if user has MFA configured."""
#     email, groups = require_auth(request)
# 
#     # Check if user has verified MFA
#     has_mfa = email in mfa_secrets and mfa_secrets[email].get("verified", False)
# 
#     return JSONResponse({
#         "email": email,
#         "mfa_enabled": has_mfa
#     })
# 
@app.get("/password-reset-info", response_class=HTMLResponse)
async def password_reset_info(request: Request):
    """Show information about resetting password."""
    email, groups = require_auth(request)

    # Cognito hosted UI domain for password reset
    cognito_domain = "employee-portal-gdg66a7d"
    reset_url = f"https://{cognito_domain}.auth.us-east-1.amazoncognito.com/forgotPassword?client_id=2hheaklvmfkpsm547p2nuab3r7&response_type=code&redirect_uri=https://portal.capsule-playground.com/oauth2/idpresponse"

    return templates.TemplateResponse("password_reset_info.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "reset_url": reset_url
    })

@app.get("/admin", response_class=HTMLResponse)
async def admin_panel(request: Request):
    """Admin panel for managing user access to areas."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        return RedirectResponse(url="/denied", status_code=303)

    try:
        # List all users in the user pool
        users_data = []
        paginator = cognito_client.get_paginator('list_users')

        for page in paginator.paginate(UserPoolId=USER_POOL_ID):
            for user in page['Users']:
                username = user['Username']
                user_email = None
                for attr in user.get('Attributes', []):
                    if attr['Name'] == 'email':
                        user_email = attr['Value']
                        break

                # Get groups for this user
                user_groups = get_user_groups(username)

                users_data.append({
                    'username': username,
                    'email': user_email,
                    'groups': user_groups
                })

        # Get all available groups
        all_groups = []
        group_paginator = cognito_client.get_paginator('list_groups')
        for page in group_paginator.paginate(UserPoolId=USER_POOL_ID):
            for group in page['Groups']:
                all_groups.append(group['GroupName'])

        response = templates.TemplateResponse("admin_panel.html", {
            "request": request,
            "email": email,
            "groups": groups,
            "users": users_data,
            "all_groups": all_groups
        })
        # Prevent browser caching of admin panel
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response
    except Exception as e:
        return templates.TemplateResponse("error.html", {
            "request": request,
            "email": email,
            "groups": groups,
            "error": f"Error loading admin panel: {str(e)}"
        })

@app.post("/admin/add-user-to-group")
async def add_user_to_group(request: Request):
    """Add a user to a group."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        return RedirectResponse(url="/denied", status_code=303)

    try:
        form_data = await request.form()
        username = form_data.get("username")
        group_name = form_data.get("group_name")

        cognito_client.admin_add_user_to_group(
            UserPoolId=USER_POOL_ID,
            Username=username,
            GroupName=group_name
        )

        # Clear entire cache to ensure fresh data
        group_cache.clear()

        # Add timestamp to prevent browser caching
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?success=added&t={timestamp}", status_code=303)
    except Exception as e:
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?error={str(e)}&t={timestamp}", status_code=303)

@app.post("/admin/remove-user-from-group")
async def remove_user_from_group(request: Request):
    """Remove a user from a group."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        return RedirectResponse(url="/denied", status_code=303)

    try:
        form_data = await request.form()
        username = form_data.get("username")
        group_name = form_data.get("group_name")

        cognito_client.admin_remove_user_from_group(
            UserPoolId=USER_POOL_ID,
            Username=username,
            GroupName=group_name
        )

        # Clear entire cache to ensure fresh data
        group_cache.clear()

        # Add timestamp to prevent browser caching
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?success=removed&t={timestamp}", status_code=303)
    except Exception as e:
        return RedirectResponse(url=f"/admin?error={str(e)}", status_code=303)

@app.post("/admin/create-user")
async def create_user(request: Request):
    """Create a new user in the user pool."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        return RedirectResponse(url="/denied", status_code=303)

    try:
        form_data = await request.form()
        user_email = form_data.get("email")
        temporary_password = form_data.get("temp_password", "TempPass123!")

        # Create user
        cognito_client.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=user_email,
            UserAttributes=[
                {'Name': 'email', 'Value': user_email},
                {'Name': 'email_verified', 'Value': 'true'}
            ],
            TemporaryPassword=temporary_password,
            MessageAction='SUPPRESS'  # Don't send email, admin will provide password
        )

        # Clear entire cache to ensure fresh data
        group_cache.clear()

        # Add timestamp to prevent browser caching
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?success=created&t={timestamp}", status_code=303)
    except Exception as e:
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?error={str(e)}&t={timestamp}", status_code=303)

@app.post("/admin/delete-user")
async def delete_user(request: Request):
    """Delete a user from the user pool."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        return RedirectResponse(url="/denied", status_code=303)

    try:
        form_data = await request.form()
        username = form_data.get("username")

        # Delete user
        cognito_client.admin_delete_user(
            UserPoolId=USER_POOL_ID,
            Username=username
        )

        # Clear entire cache to ensure fresh data
        group_cache.clear()

        # Add timestamp to prevent browser caching
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?success=deleted&t={timestamp}", status_code=303)
    except Exception as e:
        import time as time_module
        timestamp = int(time_module.time())
        return RedirectResponse(url=f"/admin?error={str(e)}&t={timestamp}", status_code=303)

# EC2 Resources Management Routes
@app.get("/ec2-resources", response_class=HTMLResponse)
async def ec2_resources_page(request: Request):
    """EC2 Resources management page (available to all authenticated users)."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("ec2_resources.html", {
        "request": request,
        "email": email,
        "groups": groups
    })

@app.get("/api/ec2/instances")
async def get_ec2_instances_api(request: Request):
    """API endpoint to get EC2 instances with VibeCodeArea tag (available to all authenticated users)."""
    email, groups = require_auth(request)

    instances = get_instances_by_tag()
    return {"instances": instances}

@app.post("/api/ec2/tag-instance")
async def tag_ec2_instance_api(request: Request):
    """API endpoint to tag an EC2 instance with area (admin only)."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        raise HTTPException(status_code=403, detail="Admin access required")

    try:
        data = await request.json()
        instance_id = data.get("instance_id")
        area = data.get("area")

        if not instance_id or not area:
            return {"success": False, "message": "Missing instance_id or area"}

        success, message = tag_instance(instance_id, area)
        return {"success": success, "message": message}
    except Exception as e:
        return {"success": False, "message": f"Error: {str(e)}"}

@app.post("/api/users/create")
async def create_user_api(request: Request):
    """API endpoint to create a new Cognito user (admin only)."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        raise HTTPException(status_code=403, detail="Admin access required")

    try:
        data = await request.json()
        user_email = data.get("email")
        user_groups = data.get("groups", [])

        if not user_email:
            return {"success": False, "message": "Missing email"}

        # Validate email format
        import re
        if not re.match(r"[^@]+@[^@]+\.[^@]+", user_email):
            return {"success": False, "message": "Invalid email format"}

        success, message = create_cognito_user(user_email, user_groups)
        return {"success": success, "message": message}
    except Exception as e:
        return {"success": False, "message": f"Error: {str(e)}"}

@app.post("/api/users/delete")
async def delete_user_api(request: Request):
    """API endpoint to delete a Cognito user (admin only)."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        raise HTTPException(status_code=403, detail="Admin access required")

    try:
        data = await request.json()
        user_email = data.get("email")

        if not user_email:
            return {"success": False, "message": "Missing email"}

        # Prevent self-deletion
        if user_email == email:
            return {"success": False, "message": "Cannot delete your own account"}

        success, message = delete_cognito_user(user_email)
        return {"success": success, "message": message}
    except Exception as e:
        return {"success": False, "message": f"Error: {str(e)}"}

# ============================================================================
# PASSWORD RESET CUSTOM FLOW
# ============================================================================

@app.get("/password-reset", response_class=HTMLResponse)
async def password_reset_page(request: Request):
    """Custom password reset flow page (no auth required)."""
    return templates.TemplateResponse("password_reset.html", {
        "request": request
    })

@app.get("/password-reset-success", response_class=HTMLResponse)
async def password_reset_success_page(request: Request):
    """Password reset success page."""
    return templates.TemplateResponse("password_reset_success.html", {
        "request": request
    })

@app.post("/api/password-reset/send-code")
async def send_reset_code_api(request: Request):
    """API: Send password reset code to user's email."""
    try:
        data = await request.json()
        email = data.get("email", "").strip().lower()

        if not email:
            return {"success": False, "error": "invalid_email", "message": "Email is required"}

        # Call Cognito to send reset code
        response = cognito_client.forgot_password(
            ClientId=CLIENT_ID,
            Username=email,
            SecretHash=get_secret_hash(email)
        )

        # Get delivery destination (masked email)
        destination = response.get('CodeDeliveryDetails', {}).get('Destination', 'your email')

        return {
            "success": True,
            "destination": destination
        }

    except cognito_client.exceptions.UserNotFoundException:
        # Don't reveal if user exists - return success anyway for security
        return {
            "success": True,
            "destination": "u***@example.com"
        }
    except cognito_client.exceptions.InvalidParameterException as e:
        return {
            "success": False,
            "error": "invalid_email",
            "message": "Invalid email format"
        }
    except cognito_client.exceptions.LimitExceededException:
        return {
            "success": False,
            "error": "rate_limit",
            "message": "Too many requests. Please try again later."
        }
    except Exception as e:
        import traceback
        print(f"Error sending reset code: {e}")
        print(traceback.format_exc())
        return {
            "success": False,
            "error": "unknown",
            "message": f"An error occurred: {str(e)}"
        }

@app.post("/api/password-reset/verify-code")
async def verify_reset_code_api(request: Request):
    """API: Verify the reset code format (actual verification happens on confirm)."""
    try:
        data = await request.json()
        code = data.get("code", "").strip()

        if not code:
            return {"success": False, "error": "invalid_code", "message": "Code is required"}

        # Basic validation - 6 digits
        if not code.isdigit() or len(code) != 6:
            return {"success": False, "error": "invalid_format", "message": "Code must be 6 digits"}

        # Don't verify with Cognito yet - that happens on confirm
        # This just validates format
        return {"success": True}

    except Exception as e:
        print(f"Error verifying code: {e}")
        return {
            "success": False,
            "error": "unknown",
            "message": "An error occurred"
        }

@app.post("/api/password-reset/confirm")
async def confirm_password_reset_api(request: Request):
    """API: Confirm password reset with code and new password."""
    try:
        data = await request.json()
        email = data.get("email", "").strip().lower()
        code = data.get("code", "").strip()
        password = data.get("password", "")

        if not email or not code or not password:
            return {
                "success": False,
                "error": "missing_fields",
                "message": "All fields are required"
            }

        # Validate password requirements
        if len(password) < 8:
            return {"success": False, "error": "weak_password", "message": "Password must be at least 8 characters"}
        if not re.search(r'[A-Z]', password):
            return {"success": False, "error": "weak_password", "message": "Password must contain an uppercase letter"}
        if not re.search(r'[a-z]', password):
            return {"success": False, "error": "weak_password", "message": "Password must contain a lowercase letter"}
        if not re.search(r'[0-9]', password):
            return {"success": False, "error": "weak_password", "message": "Password must contain a number"}
        if not re.search(r'[!@#$%^&*(),.?":{}|<>]', password):
            return {"success": False, "error": "weak_password", "message": "Password must contain a special character"}

        # Confirm password reset with Cognito
        cognito_client.confirm_forgot_password(
            ClientId=CLIENT_ID,
            Username=email,
            ConfirmationCode=code,
            Password=password,
            SecretHash=get_secret_hash(email)
        )

        return {"success": True}

    except cognito_client.exceptions.ExpiredCodeException:
        return {
            "success": False,
            "error": "expired",
            "message": "Your code has expired. Please request a new code."
        }
    except cognito_client.exceptions.CodeMismatchException:
        return {
            "success": False,
            "error": "invalid_code",
            "message": "Incorrect code. Please check your email and try again."
        }
    except cognito_client.exceptions.InvalidPasswordException:
        return {
            "success": False,
            "error": "weak_password",
            "message": "Password does not meet requirements"
        }
    except cognito_client.exceptions.LimitExceededException:
        return {
            "success": False,
            "error": "rate_limit",
            "message": "Too many attempts. Please try again later."
        }
    except cognito_client.exceptions.UserNotFoundException:
        return {
            "success": False,
            "error": "user_not_found",
            "message": "User not found"
        }
    except Exception as e:
        print(f"Error confirming password reset: {e}")
        return {
            "success": False,
            "error": "unknown",
            "message": f"An error occurred: {str(e)}"
        }

EOFAPP

# Create templates directory
mkdir -p /opt/employee-portal/templates

# Create base template
cat > /opt/employee-portal/templates/base.html << 'EOFBASE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}CAPSULE PORTAL v1.0{% endblock %}</title>
    <link href="https://fonts.googleapis.com/css2?family=Source+Code+Pro:wght@400;700&family=Courier+Prime&display=swap" rel="stylesheet">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        @keyframes matrix-glow {
            0%, 100% {
                text-shadow: 0 0 10px #00ff00, 0 0 20px #00ff00, 0 0 30px #00ff00;
                opacity: 1;
            }
            50% {
                text-shadow: 0 0 5px #00ff00, 0 0 10px #00ff00, 0 0 15px #00ff00;
                opacity: 0.8;
            }
        }

        @keyframes text-flicker {
            0% { opacity: 0.95; }
            2% { opacity: 1; }
            4% { opacity: 0.97; }
            100% { opacity: 1; }
        }

        body {
            font-family: 'Source Code Pro', 'Courier Prime', monospace;
            line-height: 1.6;
            color: #00ff00;
            background: #000000;
            position: relative;
            overflow-x: hidden;
        }

        #matrix-canvas {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: 0;
            opacity: 0.15;
        }

        header {
            background: rgba(0, 0, 0, 0.9);
            border-bottom: 2px solid #00ff00;
            color: #00ff00;
            padding: 1.5rem 2rem;
            box-shadow: 0 2px 20px rgba(0, 255, 0, 0.5);
            position: relative;
            z-index: 10;
        }

        header h1 {
            font-family: 'Source Code Pro', monospace;
            font-size: 1.8rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 5px;
            text-align: center;
            animation: matrix-glow 3s ease-in-out infinite;
        }

        header::before {
            content: '[ CONNECTED ]';
            position: absolute;
            top: 0.8rem;
            right: 2rem;
            font-size: 0.8rem;
            color: #00ff00;
            opacity: 0.7;
            animation: text-flicker 5s infinite;
        }

        nav {
            background: rgba(0, 20, 0, 0.8);
            border-bottom: 1px solid #00ff00;
            padding: 0;
            margin: 0;
            box-shadow: 0 2px 15px rgba(0, 255, 0, 0.3);
            position: relative;
            z-index: 10;
        }

        nav a {
            font-family: 'Source Code Pro', monospace;
            color: #00ff00;
            text-decoration: none;
            padding: 1rem 1.5rem;
            display: inline-block;
            border-right: 1px solid rgba(0, 255, 0, 0.2);
            background: transparent;
            font-size: 0.95rem;
            text-transform: uppercase;
            transition: all 0.2s;
            letter-spacing: 1px;
        }

        nav a:hover {
            background: rgba(0, 255, 0, 0.1);
            text-shadow: 0 0 10px #00ff00;
        }

        nav a::before {
            content: '> ';
            opacity: 0;
            transition: opacity 0.2s;
        }

        nav a:hover::before {
            opacity: 1;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 2rem;
            position: relative;
            z-index: 1;
        }

        .card {
            background: rgba(0, 10, 0, 0.85);
            border: 1px solid #00ff00;
            padding: 2rem;
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.2);
            margin-bottom: 2rem;
            position: relative;
            backdrop-filter: blur(2px);
        }

        .card::before {
            content: '> AUTHORIZED ACCESS';
            position: absolute;
            top: -12px;
            left: 20px;
            background: #000;
            padding: 0 10px;
            color: #00ff00;
            font-size: 0.75rem;
            letter-spacing: 2px;
        }

        .card h2 {
            font-family: 'Source Code Pro', monospace;
            color: #00ff00;
            font-size: 1.4rem;
            font-weight: 700;
            margin-bottom: 1.5rem;
            text-shadow: 0 0 10px #00ff00;
            letter-spacing: 2px;
        }

        .user-info {
            background: rgba(0, 30, 0, 0.5);
            border-left: 3px solid #00ff00;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
            font-size: 1rem;
        }

        .user-info strong {
            color: #00ff00;
            text-shadow: 0 0 5px #00ff00;
        }

        .badge {
            display: inline-block;
            background: rgba(0, 0, 0, 0.8);
            color: #00ff00;
            border: 1px solid #00ff00;
            padding: 0.4rem 1rem;
            font-size: 0.85rem;
            margin-right: 0.5rem;
            margin-bottom: 0.5rem;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .badge.admin {
            color: #ff0000;
            border-color: #ff0000;
            animation: matrix-glow 2s ease-in-out infinite;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 1rem;
            font-size: 0.95rem;
        }

        th, td {
            padding: 1rem;
            text-align: left;
            border: 1px solid rgba(0, 255, 0, 0.3);
        }

        th {
            background: rgba(0, 50, 0, 0.5);
            color: #00ff00;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        tr {
            background: rgba(0, 10, 0, 0.3);
            transition: background 0.2s;
        }

        tr:hover {
            background: rgba(0, 30, 0, 0.6);
        }

        .area-link {
            display: inline-block;
            background: rgba(0, 0, 0, 0.9);
            color: #00ff00;
            border: 2px solid #00ff00;
            padding: 1rem 2rem;
            text-decoration: none;
            margin: 0.5rem;
            font-size: 0.9rem;
            text-transform: uppercase;
            transition: all 0.3s;
            letter-spacing: 2px;
            font-weight: 700;
        }

        .area-link:hover {
            background: rgba(0, 255, 0, 0.1);
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.5), inset 0 0 20px rgba(0, 255, 0, 0.1);
            transform: translateY(-2px);
        }

        .denied {
            background: rgba(20, 0, 0, 0.8);
            border-left: 4px solid #ff0000;
            padding: 1.5rem;
            font-size: 1rem;
        }

        .denied strong {
            color: #ff0000;
            text-shadow: 0 0 5px #ff0000;
        }

        footer {
            text-align: center;
            padding: 2rem;
            color: rgba(0, 255, 0, 0.5);
            font-size: 0.85rem;
            border-top: 1px solid rgba(0, 255, 0, 0.2);
            margin-top: 3rem;
            position: relative;
            z-index: 10;
            letter-spacing: 2px;
        }

        p {
            font-size: 1rem;
            line-height: 1.8;
        }

        .crt-container {
            padding: 2rem;
        }

        .content-box {
            background: rgba(0, 10, 0, 0.85);
            border: 1px solid #00ff00;
            padding: 2rem;
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.2);
            margin-top: 2rem;
            backdrop-filter: blur(2px);
        }

        .content-box h2 {
            font-family: 'Source Code Pro', monospace;
            color: #00ff00;
            font-size: 1.3rem;
            font-weight: 700;
            margin-bottom: 1.5rem;
            text-shadow: 0 0 10px #00ff00;
        }

        .content-box h3 {
            color: #00ff00;
            font-size: 1.1rem;
            font-weight: 700;
            margin-top: 1.5rem;
            margin-bottom: 1rem;
            opacity: 0.9;
        }

        .info-section {
            background: rgba(0, 30, 0, 0.5);
            border-left: 3px solid #00ff00;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
            font-size: 0.95rem;
        }

        .info-section ol, .info-section ul {
            margin-left: 2rem;
            margin-top: 1rem;
        }

        .info-section li {
            margin-bottom: 0.8rem;
            line-height: 1.6;
        }

        .warning-box {
            background: rgba(20, 0, 0, 0.7);
            border-left: 4px solid #ff0000;
            padding: 1.5rem;
            margin: 1.5rem 0;
            font-size: 0.95rem;
        }

        .warning-box p {
            color: #ff0000;
            text-shadow: 0 0 5px #ff0000;
        }

        .error-box {
            background: rgba(20, 0, 0, 0.85);
            border: 2px solid #ff0000;
            padding: 2rem;
            margin-top: 2rem;
        }

        .error-box h2 {
            color: #ff0000;
            font-size: 1.2rem;
            font-weight: 700;
            margin-bottom: 1.5rem;
            text-shadow: 0 0 10px #ff0000;
        }

        .error-message {
            font-size: 1rem;
            color: #ff0000;
            margin-bottom: 1.5rem;
        }

        .ascii-art {
            font-family: 'Courier Prime', monospace;
            font-size: 0.7rem;
            color: #00ff00;
            text-align: center;
            margin-bottom: 2rem;
            text-shadow: 0 0 10px #00ff00;
            line-height: 1.2;
        }

        .ascii-art.error {
            color: #ff0000;
            text-shadow: 0 0 10px #ff0000;
        }

        .button-group {
            margin-top: 2rem;
            display: flex;
            gap: 1rem;
            flex-wrap: wrap;
        }

        .btn-primary, .btn-secondary {
            font-family: 'Source Code Pro', monospace;
            display: inline-block;
            padding: 0.8rem 1.5rem;
            font-size: 0.85rem;
            text-decoration: none;
            border: 2px solid;
            background: rgba(0, 0, 0, 0.9);
            text-transform: uppercase;
            transition: all 0.3s;
            cursor: pointer;
            letter-spacing: 1px;
            font-weight: 700;
        }

        .btn-primary {
            color: #00ff00;
            border-color: #00ff00;
        }

        .btn-primary:hover {
            background: rgba(0, 255, 0, 0.1);
            box-shadow: 0 0 15px rgba(0, 255, 0, 0.5);
        }

        .btn-secondary {
            color: #00ff00;
            border-color: #00ff00;
            opacity: 0.7;
        }

        .btn-secondary:hover {
            background: rgba(0, 255, 0, 0.05);
            opacity: 1;
        }

        .nav-links {
            margin-top: 2rem;
        }

        .nav-links a {
            display: inline-block;
            color: #00ff00;
            text-decoration: none;
            padding: 0.5rem 1rem;
            border: 1px solid #00ff00;
            font-size: 0.9rem;
            transition: all 0.2s;
            margin-right: 1rem;
        }

        .nav-links a:hover {
            background: rgba(0, 255, 0, 0.1);
            box-shadow: 0 0 10px rgba(0, 255, 0, 0.5);
        }
    </style>
</head>
<body>
    <canvas id="matrix-canvas"></canvas>

    <header>
        <h1>// CAPSULE ACCESS MAINFRAME //</h1>
    </header>

    <nav>
        <a href="/">Home</a>
        <a href="/directory">Directory</a>
        <a href="/ec2-resources">EC2 Resources</a>
        <a href="/areas/engineering">Engineering</a>
        <a href="/areas/hr">HR</a>
        <a href="/areas/automation">Automation</a>
        <a href="/areas/product">Product</a>
        {% if groups and 'admins' in groups %}
        <a href="/admin" style="border-left: 2px solid #ff0000; color: #ff0000;">Admin Panel</a>
        {% endif %}
        <a href="/logout" style="float: right; border-left: 2px solid rgba(255, 255, 255, 0.3); opacity: 0.7;">Logout</a>
    </nav>

    <div class="container">
        {% block content %}{% endblock %}
    </div>

    <footer>
        CAPSULE_PORTAL_v1.0 // COGNITO_AUTH // ALB_GATEWAY // ESTABLISHED_2026
    </footer>

    <script>
        // Matrix Digital Rain Effect
        const canvas = document.getElementById('matrix-canvas');
        const ctx = canvas.getContext('2d');

        canvas.width = window.innerWidth;
        canvas.height = window.innerHeight;

        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@#$%^&*()_+-=[]{}|;:,.<>?/~';
        const fontSize = 14;
        const columns = canvas.width / fontSize;

        const drops = [];
        for (let i = 0; i < columns; i++) {
            drops[i] = Math.random() * -100;
        }

        function draw() {
            ctx.fillStyle = 'rgba(0, 0, 0, 0.05)';
            ctx.fillRect(0, 0, canvas.width, canvas.height);

            ctx.fillStyle = '#00ff00';
            ctx.font = fontSize + 'px monospace';

            for (let i = 0; i < drops.length; i++) {
                const text = chars[Math.floor(Math.random() * chars.length)];
                ctx.fillText(text, i * fontSize, drops[i] * fontSize);

                if (drops[i] * fontSize > canvas.height && Math.random() > 0.975) {
                    drops[i] = 0;
                }
                drops[i]++;
            }
        }

        setInterval(draw, 33);

        window.addEventListener('resize', () => {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
        });
    </script>
</body>
</html>
EOFBASE

# Create home template
cat > /opt/employee-portal/templates/home.html << 'EOFHOME'
{% extends "base.html" %}

{% block title %}Home - Employee Access Portal{% endblock %}

{% block content %}
<div class="card">
    <h2>Welcome to the Employee Access Portal</h2>

    <div class="user-info">
        <p><strong>Logged in as:</strong> {{ email }}</p>
        <p><strong>Your Groups:</strong></p>
        <div>
            {% for group in groups %}
                <span class="badge {% if group == 'admins' %}admin{% endif %}">{{ group }}</span>
            {% endfor %}
        </div>
    </div>

    <h3>Your Allowed Areas</h3>
    {% if allowed_areas %}
        <div>
            {% for area in allowed_areas %}
                <a href="{{ area.url }}" class="area-link">{{ area.name }}</a>
            {% endfor %}
        </div>
    {% else %}
        <p>You do not have access to any areas yet. Please contact your administrator.</p>
    {% endif %}

    <h3 style="margin-top: 2rem;">Account Security</h3>
    <div style="margin-top: 1rem;">
        <a href="/settings" class="area-link" style="background: #006400; border-color: #00ff00;">⚙️ Account Settings</a>
    </div>
</div>
{% endblock %}
EOFHOME

# Create directory template
cat > /opt/employee-portal/templates/directory.html << 'EOFDIRECTORY'
{% extends "base.html" %}

{% block title %}Directory - Employee Access Portal{% endblock %}

{% block content %}
<div class="card">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
        <div>
            <h2>Employee Directory</h2>
            <p>All registered users in the Cognito user pool.</p>
        </div>
        <div style="display: flex; gap: 1rem; align-items: center;">
            <div style="display: flex; align-items: center; gap: 0.5rem;">
                <label style="color: #00ff00; font-family: 'Source Code Pro', monospace; font-size: 0.9rem;">Timezone:</label>
                <select id="timezone-selector" onchange="changeTimezone()" style="background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.5rem; font-family: 'Source Code Pro', monospace; cursor: pointer;">
                    <option value="America/New_York">East Coast (ET)</option>
                    <option value="America/Chicago">Central (CT)</option>
                    <option value="America/Denver">Mountain (MT)</option>
                    <option value="America/Los_Angeles">West Coast (PT)</option>
                    <option value="UTC">UTC</option>
                    <option value="Europe/London">London (GMT)</option>
                    <option value="Europe/Paris">Paris (CET)</option>
                    <option value="Asia/Tokyo">Tokyo (JST)</option>
                </select>
            </div>
            {% if is_admin %}
            <button onclick="openAddUserModal()" style="background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.75rem 1.5rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                + ADD USER
            </button>
            {% endif %}
        </div>
    </div>

    <div id="status-message" style="display: none; padding: 1rem; margin-bottom: 1rem; border-radius: 4px;"></div>

    <table>
        <thead>
            <tr>
                <th>Email</th>
                <th>Last Login</th>
                <th>Groups</th>
                {% if is_admin %}
                <th>Actions</th>
                {% endif %}
            </tr>
        </thead>
        <tbody>
            {% for user in users %}
            <tr>
                <td>{{ user.email }}</td>
                <td class="timestamp-cell" data-utc="{{ user.last_login }}" style="color: {% if user.last_login == 'Never' %}#ffaa00{% else %}#00ff00{% endif %};">
                    {{ user.last_login }}
                </td>
                <td>{{ user.groups }}</td>
                {% if is_admin %}
                <td>
                    <button onclick="confirmDelete('{{ user.email }}')"
                            style="background: rgba(255, 0, 0, 0.2); border: 1px solid #ff0000; color: #ff0000; padding: 0.4rem 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-size: 0.85rem; text-transform: uppercase;">
                        DELETE
                    </button>
                </td>
                {% endif %}
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>

{% if is_admin %}
<!-- Add User Modal -->
<div id="add-user-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; justify-content: center; align-items: center;">
    <div style="background: rgba(0, 20, 0, 0.95); border: 2px solid #00ff00; padding: 2rem; max-width: 500px; width: 90%; box-shadow: 0 0 30px rgba(0, 255, 0, 0.5);">
        <h3 style="color: #00ff00; margin-bottom: 1.5rem;">ADD NEW USER</h3>

        <div style="margin-bottom: 1rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Email Address:</label>
            <input type="email" id="user-email-input" placeholder="user@capsule.com"
                   style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
        </div>

        <div style="margin-bottom: 1.5rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Assign to Groups (select multiple):</label>
            <div style="background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; padding: 0.8rem;">
                <label style="display: block; margin-bottom: 0.5rem; cursor: pointer;">
                    <input type="checkbox" value="engineering" style="margin-right: 0.5rem;"> Engineering
                </label>
                <label style="display: block; margin-bottom: 0.5rem; cursor: pointer;">
                    <input type="checkbox" value="hr" style="margin-right: 0.5rem;"> HR
                </label>
                <label style="display: block; margin-bottom: 0.5rem; cursor: pointer;">
                    <input type="checkbox" value="product" style="margin-right: 0.5rem;"> Product
                </label>
                <label style="display: block; margin-bottom: 0.5rem; cursor: pointer;">
                    <input type="checkbox" value="automation" style="margin-right: 0.5rem;"> Automation
                </label>
                <label style="display: block; cursor: pointer;">
                    <input type="checkbox" value="admins" style="margin-right: 0.5rem;"> Admins
                </label>
            </div>
        </div>

        <div style="display: flex; gap: 1rem;">
            <button onclick="createUser()"
                    style="flex: 1; background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                CREATE
            </button>
            <button onclick="closeAddUserModal()"
                    style="flex: 1; background: rgba(255, 0, 0, 0.2); border: 2px solid #ff0000; color: #ff0000; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                CANCEL
            </button>
        </div>
    </div>
</div>

<script>
function openAddUserModal() {
    document.getElementById('add-user-modal').style.display = 'flex';
    document.getElementById('user-email-input').value = '';
    // Uncheck all checkboxes
    document.querySelectorAll('#add-user-modal input[type="checkbox"]').forEach(cb => cb.checked = false);
}

function closeAddUserModal() {
    document.getElementById('add-user-modal').style.display = 'none';
}

function showStatus(message, type) {
    const statusDiv = document.getElementById('status-message');
    statusDiv.textContent = message;
    statusDiv.style.display = 'block';
    statusDiv.style.background = type === 'success' ? 'rgba(0, 255, 0, 0.1)' : 'rgba(255, 0, 0, 0.1)';
    statusDiv.style.color = type === 'success' ? '#00ff00' : '#ff0000';
    statusDiv.style.border = type === 'success' ? '1px solid #00ff00' : '1px solid #ff0000';

    setTimeout(() => {
        statusDiv.style.display = 'none';
    }, 5000);
}

async function createUser() {
    const email = document.getElementById('user-email-input').value.trim();

    if (!email) {
        showStatus('Please enter an email address', 'error');
        return;
    }

    // Get selected groups
    const groups = [];
    document.querySelectorAll('#add-user-modal input[type="checkbox"]:checked').forEach(cb => {
        groups.push(cb.value);
    });

    try {
        const response = await fetch('/api/users/create', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                email: email,
                groups: groups
            })
        });

        const data = await response.json();

        if (data.success) {
            showStatus(data.message, 'success');
            closeAddUserModal();
            // Reload page to show new user
            setTimeout(() => location.reload(), 2000);
        } else {
            showStatus(data.message, 'error');
        }
    } catch (error) {
        showStatus('Error creating user: ' + error.message, 'error');
    }
}

// Close modal on Escape key
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeAddUserModal();
    }
});

// Delete user functionality
function confirmDelete(email) {
    if (confirm(`Are you sure you want to delete user: ${email}?\n\nThis action cannot be undone.`)) {
        deleteUser(email);
    }
}

async function deleteUser(email) {
    try {
        const response = await fetch('/api/users/delete', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                email: email
            })
        });

        const data = await response.json();

        if (data.success) {
            showStatus(data.message, 'success');
            // Reload page to show updated user list
            setTimeout(() => location.reload(), 1500);
        } else {
            showStatus(data.message, 'error');
        }
    } catch (error) {
        showStatus('Error deleting user: ' + error.message, 'error');
    }
}

// Timezone conversion functionality
function convertTimestamps() {
    const timezone = document.getElementById('timezone-selector').value;
    const cells = document.querySelectorAll('.timestamp-cell');

    cells.forEach(cell => {
        const utcTime = cell.getAttribute('data-utc');

        if (utcTime === 'Never') {
            cell.textContent = 'Never';
            return;
        }

        try {
            // Parse UTC time (format: "2026-01-27 22:01 UTC")
            const dateStr = utcTime.replace(' UTC', '');
            const date = new Date(dateStr + ' UTC');

            // Format in selected timezone
            const options = {
                year: 'numeric',
                month: '2-digit',
                day: '2-digit',
                hour: '2-digit',
                minute: '2-digit',
                timeZone: timezone,
                hour12: false
            };

            const formatter = new Intl.DateTimeFormat('en-US', options);
            const parts = formatter.formatToParts(date);

            // Build formatted string
            let formatted = '';
            parts.forEach(part => {
                if (part.type === 'month') formatted += part.value + '/';
                if (part.type === 'day') formatted += part.value + '/';
                if (part.type === 'year') formatted += part.value + ' ';
                if (part.type === 'hour') formatted += part.value + ':';
                if (part.type === 'minute') formatted += part.value;
            });

            // Add timezone abbreviation
            const tzAbbr = {
                'America/New_York': 'ET',
                'America/Chicago': 'CT',
                'America/Denver': 'MT',
                'America/Los_Angeles': 'PT',
                'UTC': 'UTC',
                'Europe/London': 'GMT',
                'Europe/Paris': 'CET',
                'Asia/Tokyo': 'JST'
            };

            cell.textContent = formatted + ' ' + (tzAbbr[timezone] || timezone);
        } catch (e) {
            console.error('Error converting timestamp:', e);
            cell.textContent = utcTime;
        }
    });
}

function changeTimezone() {
    const timezone = document.getElementById('timezone-selector').value;
    localStorage.setItem('preferredTimezone', timezone);
    convertTimestamps();
}

// Load saved timezone preference (default to East Coast)
document.addEventListener('DOMContentLoaded', () => {
    const savedTimezone = localStorage.getItem('preferredTimezone') || 'America/New_York';
    document.getElementById('timezone-selector').value = savedTimezone;
    convertTimestamps();
});
</script>
{% endif %}

{% endblock %}
EOFDIRECTORY

# Create area template
cat > /opt/employee-portal/templates/area.html << 'EOFAREA'
{% extends "base.html" %}

{% block title %}{{ area_name }} - Employee Access Portal{% endblock %}

{% block content %}
<div class="card">
    <h2>{{ area_name }} Area</h2>

    <div class="user-info">
        <p><strong>Logged in as:</strong> {{ email }}</p>
    </div>

    <p>{{ area_description }}</p>

    <div style="margin-top: 2rem; padding: 1rem; background: #e8f5e9; border-radius: 4px;">
        <p><strong>Access Granted:</strong> You have permission to access this area.</p>
    </div>
</div>
{% endblock %}
EOFAREA

# Create denied template
cat > /opt/employee-portal/templates/denied.html << 'EOFDENIED'
{% extends "base.html" %}

{% block title %}Access Denied - Employee Access Portal{% endblock %}

{% block content %}
<div class="card">
    <h2>Access Denied</h2>

    <div class="denied">
        <p><strong>You do not have permission to access this area.</strong></p>
        <p>Logged in as: {{ email }}</p>
    </div>

    <p style="margin-top: 1rem;">
        If you believe you should have access to this area, please contact your administrator.
    </p>

    <a href="/" class="area-link" style="margin-top: 1rem;">Return to Home</a>
</div>
{% endblock %}
EOFDENIED

# Create logged out template
cat > /opt/employee-portal/templates/logged_out.html << 'EOFLOGGEDOUT'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Logged Out - CAPSULE ACCESS MAINFRAME</title>
    <link href="https://fonts.googleapis.com/css2?family=Source+Code+Pro:wght@400;700&display=swap" rel="stylesheet">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Source Code Pro', monospace;
            background: #000;
            color: #00ff00;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 2rem;
        }

        .container {
            max-width: 600px;
            text-align: center;
            border: 2px solid #00ff00;
            padding: 3rem;
            background: rgba(0, 255, 0, 0.05);
        }

        h1 {
            font-size: 2rem;
            margin-bottom: 2rem;
            text-transform: uppercase;
            letter-spacing: 2px;
            color: #00ff00;
        }

        p {
            font-size: 1.1rem;
            line-height: 1.8;
            margin-bottom: 2rem;
        }

        .status {
            font-size: 3rem;
            margin-bottom: 1rem;
        }

        a {
            display: inline-block;
            margin-top: 1rem;
            padding: 1rem 2rem;
            background: rgba(0, 255, 0, 0.2);
            border: 2px solid #00ff00;
            color: #00ff00;
            text-decoration: none;
            text-transform: uppercase;
            font-weight: 700;
            letter-spacing: 1px;
            transition: all 0.3s ease;
        }

        a:hover {
            background: rgba(0, 255, 0, 0.3);
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0, 255, 0, 0.3);
        }

        .blink {
            animation: blink 1s infinite;
        }

        @keyframes blink {
            0%, 50% { opacity: 1; }
            51%, 100% { opacity: 0; }
        }
    </style>
    <script>
        function clearAllSessionData() {
            // Clear all cookies aggressively
            const cookiesToClear = [
                'AWSELBAuthSessionCookie',
                'AWSELBAuthSessionCookie-0',
                'AWSELBAuthSessionCookie-1',
                'AWSELBAuthSessionCookie-2'
            ];

            // Clear specific auth cookies
            cookiesToClear.forEach(function(cookieName) {
                document.cookie = cookieName + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;";
                document.cookie = cookieName + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.capsule-playground.com;";
                document.cookie = cookieName + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=portal.capsule-playground.com;";
                document.cookie = cookieName + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.portal.capsule-playground.com;";
            });

            // Clear all other cookies
            document.cookie.split(";").forEach(function(c) {
                var eqPos = c.indexOf("=");
                var name = eqPos > -1 ? c.substr(0, eqPos).trim() : c.trim();
                if (name) {
                    document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;";
                    document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.capsule-playground.com;";
                    document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=portal.capsule-playground.com;";
                }
            });

            // Clear storage
            try { localStorage.clear(); } catch(e) {}
            try { sessionStorage.clear(); } catch(e) {}
        }

        function clearAndReturn() {
            clearAllSessionData();
            // Force navigation to portal (ALB will require re-authentication)
            window.location.replace("https://portal.capsule-playground.com");
            return false;
        }

        // Auto-clear cookies on page load
        document.addEventListener('DOMContentLoaded', function() {
            clearAllSessionData();
            console.log('Session data cleared automatically');
        });
    </script>
</head>
<body>
    <div class="container">
        <div class="status">✓</div>
        <h1>// LOGOUT SUCCESSFUL //</h1>
        <p>You have been successfully logged out of the CAPSULE ACCESS MAINFRAME.</p>
        <p>All session data has been cleared.</p>
        <p style="font-size: 0.9rem; opacity: 0.7;">Click below to log in again. You will be required to enter your credentials.</p>
        <a href="#" onclick="return clearAndReturn();">← RETURN TO LOGIN</a>
    </div>
</body>
</html>
EOFLOGGEDOUT

# Create login template
cat > /opt/employee-portal/templates/login.html << 'EOFLOGIN'
{% extends "base.html" %}
{% block title %}LOGIN - CAPSULE PORTAL{% endblock %}
{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
 ██╗      ██████╗  ██████╗ ██╗███╗   ██╗
 ██║     ██╔═══██╗██╔════╝ ██║████╗  ██║
 ██║     ██║   ██║██║  ███╗██║██╔██╗ ██║
 ██║     ██║   ██║██║   ██║██║██║╚██╗██║
 ███████╗╚██████╔╝╚██████╔╝██║██║ ╚████║
 ╚══════╝ ╚═════╝  ╚═════╝ ╚═╝╚═╝  ╚═══╝
    </pre>

    <div class="content-box">
        {% if error %}
        <div style="color: #ff0000; background: rgba(255, 0, 0, 0.1); padding: 1rem; margin-bottom: 1rem; border: 1px solid #ff0000;">
            {{ error }}
        </div>
        {% endif %}

        {% if step == 'email' %}
        <h2>// PASSWORDLESS LOGIN //</h2>
        <p style="margin: 1.5rem 0; line-height: 1.6; font-size: 0.95rem; opacity: 0.9;">
            Enter your email address. You'll receive a verification code to complete login.
        </p>
        <form method="POST" action="/login" style="margin-top: 2rem;">
            <div style="margin-bottom: 2rem;">
                <label style="display: block; margin-bottom: 0.5rem;">EMAIL:</label>
                <input type="email" name="email" placeholder="user@capsule.com" required autofocus
                       style="width: 100%; padding: 0.75rem; background: #000; border: 2px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace; font-size: 1rem;">
            </div>
            <button type="submit" style="width: 100%; padding: 1rem; background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace; font-size: 1rem; font-weight: 700; text-transform: uppercase; cursor: pointer; transition: all 0.3s;">
                SEND CODE →
            </button>
        </form>

        {% elif step == 'code' %}
        <h2>// EMAIL VERIFICATION //</h2>
        <p style="margin: 1.5rem 0; line-height: 1.6;">
            A 6-digit verification code has been sent to:<br>
            <strong style="color: #00ff00;">{{ email }}</strong>
        </p>
        <p style="margin-bottom: 2rem; font-size: 0.9rem; opacity: 0.8;">
            Check your email and enter the code below. Code expires in 5 minutes.
        </p>
        <form method="POST" action="/verify-code">
            <div style="margin-bottom: 2rem;">
                <label style="display: block; margin-bottom: 0.5rem;">VERIFICATION CODE:</label>
                <input type="text" name="code" placeholder="000000" maxlength="6" required autofocus
                       pattern="[0-9]{6}"
                       style="width: 100%; padding: 0.75rem; background: #000; border: 2px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace; font-size: 1.5rem; text-align: center; letter-spacing: 0.5rem;">
                <input type="hidden" name="session" value="{{ session }}">
                <input type="hidden" name="email" value="{{ email }}">
            </div>
            <button type="submit" style="width: 100%; padding: 1rem; background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace; font-size: 1rem; font-weight: 700; text-transform: uppercase; cursor: pointer; transition: all 0.3s;">
                VERIFY CODE →
            </button>
        </form>
        <p style="margin-top: 1.5rem; font-size: 0.9rem; opacity: 0.6;">
            <a href="/login" style="color: #00ff00; text-decoration: none; border-bottom: 1px solid #00ff00;">← Back to login</a>
        </p>
        {% endif %}
    </div>
</div>
{% endblock %}
EOFLOGIN

# Create error template
cat > /opt/employee-portal/templates/error.html << 'EOFERROR'
{% extends "base.html" %}

{% block title %}ERROR - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art error">
  _____  ___   ___   ___   ___
 | ____|  _ \ _ \  _ \  _ \ | ___ \
 |  _| | |_) |  _/  _/| |_) |  _/ /
 | |___|  _ <| |  | |  | _ <| ||
 |_____|_| \_\_|  |_|  |_| \_\_||_|
    </pre>

    <div class="error-box">
        <h2>⚠ SYSTEM ERROR</h2>
        <p class="error-message">{{ error }}</p>
        <div class="nav-links">
            <a href="/">← RETURN TO HOME</a>
        </div>
    </div>
</div>
{% endblock %}
EOFERROR

# Create MFA setup template
cat > /opt/employee-portal/templates/mfa_setup.html << 'EOFMFA'
{% extends "base.html" %}

{% block title %}MFA SETUP - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
  __  __ _____ _
 |  \/  |  ___/ \
 | |\/| | |_ / _ \
 | |  | |  _/ ___ \
 |_|  |_|_|/_/   \_\

 MULTI-FACTOR AUTH
    </pre>

    <div class="content-box">
        <h2>🔐 ENABLE MFA FOR {{ email }}</h2>

        <div class="info-section">
            <h3>WHAT IS MFA?</h3>
            <p>Multi-Factor Authentication adds an extra layer of security to your account by requiring a time-based code from your authenticator app in addition to your password.</p>
        </div>

        <!-- Loading state -->
        <div id="loading-state" style="text-align: center; padding: 20px;">
            <p>🔄 Generating QR code...</p>
        </div>

        <!-- Error state -->
        <div id="error-state" style="display: none; text-align: center; padding: 20px;">
            <p style="color: #ff0000;">❌ <span id="error-message">Failed to initialize MFA setup</span></p>
            <button onclick="location.reload()" class="btn-primary">Retry</button>
        </div>

        <!-- MFA Setup Interface -->
        <div id="mfa-setup-interface" style="display: none;">
            <!-- Step 1: Download App -->
            <div class="info-section">
                <h3>STEP 1: INSTALL AUTHENTICATOR APP</h3>
                <p>Download one of these apps on your phone:</p>
                <ul>
                    <li>Google Authenticator</li>
                    <li>Microsoft Authenticator</li>
                    <li>Authy</li>
                </ul>
            </div>

            <!-- Step 2: Scan QR Code -->
            <div class="info-section">
                <h3>STEP 2: SCAN QR CODE</h3>
                <div style="text-align: center; padding: 20px; background: #fff; border-radius: 10px; margin: 20px 0;">
                    <img id="qr-code-image" src="" alt="QR Code" style="max-width: 300px; width: 100%;" />
                </div>
                <p style="text-align: center; color: #00ff00; font-size: 0.9em;">
                    ▼ Scan this QR code with your authenticator app ▼
                </p>
            </div>

            <!-- Manual Entry Option -->
            <div class="info-section">
                <h3>CAN'T SCAN? ENTER MANUALLY</h3>
                <p>If you can't scan the QR code, enter this secret key manually in your authenticator app:</p>
                <div style="background: #000; border: 2px solid #00ff00; padding: 15px; margin: 10px 0; text-align: center; font-family: monospace; font-size: 1.2em; letter-spacing: 2px;">
                    <code id="secret-key" style="color: #00ff00;">Loading...</code>
                </div>
                <button onclick="copySecret()" class="btn-secondary" style="margin-top: 10px;">📋 Copy Secret</button>
            </div>

            <!-- Step 3: Verify Code -->
            <div class="info-section">
                <h3>STEP 3: VERIFY CODE</h3>
                <p>Enter the 6-digit code from your authenticator app:</p>

                <div style="margin: 20px 0;">
                    <input
                        type="text"
                        id="verification-code"
                        maxlength="6"
                        placeholder="000000"
                        style="width: 200px; padding: 15px; font-size: 1.5em; text-align: center; font-family: monospace; letter-spacing: 5px; background: #000; color: #00ff00; border: 2px solid #00ff00; border-radius: 5px;"
                        oninput="this.value = this.value.replace(/[^0-9]/g, '')"
                    />
                </div>

                <button onclick="verifyCode()" class="btn-primary" id="verify-button">
                    ✓ VERIFY AND ENABLE MFA
                </button>

                <div id="verification-status" style="margin-top: 20px; text-align: center;">
                    <p id="status-message" style="display: none;"></p>
                </div>
            </div>
        </div>

        <!-- Success State -->
        <div id="success-state" style="display: none; text-align: center; padding: 20px;">
            <div style="font-size: 3em; margin: 20px 0;">✅</div>
            <h3 style="color: #00ff00;">MFA SUCCESSFULLY CONFIGURED!</h3>
            <p>Your account is now protected with Multi-Factor Authentication.</p>
            <p>You'll need to enter a code from your authenticator app each time you log in.</p>
            <div style="margin-top: 30px;">
                <a href="/settings" class="btn-primary">← RETURN TO SETTINGS</a>
            </div>
        </div>

        <div class="nav-links">
            <a href="/settings">← BACK TO SETTINGS</a>
        </div>
    </div>
</div>

<style>
    .btn-primary {
        background: #00ff00;
        color: #000;
        padding: 15px 30px;
        border: none;
        border-radius: 5px;
        font-weight: bold;
        cursor: pointer;
        font-size: 1.1em;
        transition: all 0.3s;
    }

    .btn-primary:hover {
        background: #00cc00;
        transform: scale(1.05);
    }

    .btn-primary:disabled {
        background: #666;
        cursor: not-allowed;
        transform: none;
    }

    .btn-secondary {
        background: #000;
        color: #00ff00;
        padding: 10px 20px;
        border: 2px solid #00ff00;
        border-radius: 5px;
        font-weight: bold;
        cursor: pointer;
        transition: all 0.3s;
    }

    .btn-secondary:hover {
        background: #00ff00;
        color: #000;
    }

    #verification-code:focus {
        outline: none;
        border-color: #00ff00;
        box-shadow: 0 0 10px #00ff00;
    }
</style>

<script>
    let currentSecret = null;

    // Initialize MFA setup on page load
    async function initializeMFA() {
        try {
            const response = await fetch('/api/mfa/init');
            const data = await response.json();

            if (data.success) {
                // Store secret
                currentSecret = data.secret;

                // Display QR code
                document.getElementById('qr-code-image').src = data.qr_code;

                // Display secret key
                document.getElementById('secret-key').textContent = data.secret;

                // Hide loading, show interface
                document.getElementById('loading-state').style.display = 'none';
                document.getElementById('mfa-setup-interface').style.display = 'block';
            } else {
                showError('Failed to generate MFA setup');
            }
        } catch (error) {
            console.error('MFA init error:', error);
            showError('Network error. Please check your connection and try again.');
        }
    }

    // Verify the entered code
    async function verifyCode() {
        const codeInput = document.getElementById('verification-code');
        const code = codeInput.value.trim();
        const statusMsg = document.getElementById('status-message');
        const verifyButton = document.getElementById('verify-button');

        // Validate input
        if (code.length !== 6) {
            statusMsg.textContent = '❌ Please enter a 6-digit code';
            statusMsg.style.color = '#ff0000';
            statusMsg.style.display = 'block';
            return;
        }

        // Disable button and show loading
        verifyButton.disabled = true;
        verifyButton.textContent = '⏳ Verifying...';
        statusMsg.textContent = '🔄 Checking code...';
        statusMsg.style.color = '#ffff00';
        statusMsg.style.display = 'block';

        try {
            const response = await fetch('/api/mfa/verify', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ code })
            });

            const data = await response.json();

            if (data.success) {
                // Success! Show success state
                document.getElementById('mfa-setup-interface').style.display = 'none';
                document.getElementById('success-state').style.display = 'block';
            } else {
                // Invalid code
                statusMsg.textContent = '❌ ' + (data.error || 'Invalid code. Please try again.');
                statusMsg.style.color = '#ff0000';
                verifyButton.disabled = false;
                verifyButton.textContent = '✓ VERIFY AND ENABLE MFA';

                // Clear input
                codeInput.value = '';
                codeInput.focus();
            }
        } catch (error) {
            console.error('Verification error:', error);
            statusMsg.textContent = '❌ Network error. Please try again.';
            statusMsg.style.color = '#ff0000';
            verifyButton.disabled = false;
            verifyButton.textContent = '✓ VERIFY AND ENABLE MFA';
        }
    }

    // Copy secret to clipboard
    function copySecret() {
        const secretText = document.getElementById('secret-key').textContent;
        navigator.clipboard.writeText(secretText).then(() => {
            alert('✅ Secret key copied to clipboard!');
        }).catch(err => {
            console.error('Copy failed:', err);
            alert('❌ Failed to copy. Please select and copy manually.');
        });
    }

    // Show error state
    function showError(message) {
        document.getElementById('loading-state').style.display = 'none';
        document.getElementById('error-message').textContent = message;
        document.getElementById('error-state').style.display = 'block';
    }

    // Allow Enter key to verify
    document.addEventListener('DOMContentLoaded', () => {
        initializeMFA();

        document.getElementById('verification-code').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                verifyCode();
            }
        });
    });
</script>
{% endblock %}
EOFMFA

# Create password reset info template
cat > /opt/employee-portal/templates/password_reset_info.html << 'EOFRESET'
{% extends "base.html" %}

{% block title %}PASSWORD RESET - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
  ____   _   ____ ______        _____  ____  ____
 |  _ \ / \ / ___/ ___\ \      / / _ \|  _ \|  _ \
 | |_) / _ \\\___ \___ \\ \ /\ / / | | | |_) | | | |
 |  __/ ___ \___) |__) |\ V  V /| |_| |  _ <| |_| |
 |_| /_/   \_\____/____/  \_/\_/  \___/|_| \_\____/

    </pre>

    <div class="content-box">
        <h2>🔑 RESET YOUR PASSWORD</h2>

        {% if email %}
        <p>Current account: <strong>{{ email }}</strong></p>
        {% endif %}

        <div class="info-section">
            <h3>TO RESET YOUR PASSWORD:</h3>
            <ol>
                <li>Log out of the portal</li>
                <li>On the login page, click "Forgot your password?"</li>
                <li>Enter your email address</li>
                <li>Check your email for a verification code</li>
                <li>Enter the code and create a new password</li>
            </ol>
        </div>

        <div class="info-section">
            <h3>PASSWORD REQUIREMENTS:</h3>
            <ul>
                <li>Minimum 8 characters</li>
                <li>At least one uppercase letter</li>
                <li>At least one lowercase letter</li>
                <li>At least one number</li>
                <li>At least one special character (!@#$%^&*)</li>
            </ul>
        </div>

        <div class="warning-box">
            <p>⚠ You will be logged out after clicking the reset link below.</p>
        </div>

        <div class="button-group">
            <a href="{{ reset_url }}" class="btn-primary">GO TO PASSWORD RESET</a>
            <a href="/" class="btn-secondary">← CANCEL</a>
        </div>
    </div>
</div>
{% endblock %}
EOFRESET

# Create admin panel template
cat > /opt/employee-portal/templates/admin_panel.html << 'EOFADMIN'
{% extends "base.html" %}

{% block title %}ADMIN PANEL - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
     _    ____  __  __ ___ _   _
    / \  |  _ \|  \/  |_ _| \ | |
   / _ \ | | | | |\/| || ||  \| |
  / ___ \| |_| | |  | || || |\  |
 /_/   \_\____/|_|  |_|___|_| \_|

 ACCESS CONTROL PANEL
    </pre>

    <div class="content-box">
        <h2>⚡ ADMIN PANEL - USER ACCESS MANAGEMENT</h2>

        {% if request.query_params.get('success') == 'added' %}
        <div style="background: rgba(0, 100, 0, 0.5); border: 1px solid #00ff00; padding: 1rem; margin-bottom: 1rem;">
            ✓ User successfully added to group
        </div>
        {% elif request.query_params.get('success') == 'removed' %}
        <div style="background: rgba(100, 100, 0, 0.5); border: 1px solid #ffff00; padding: 1rem; margin-bottom: 1rem;">
            ✓ User successfully removed from group
        </div>
        {% elif request.query_params.get('success') == 'created' %}
        <div style="background: rgba(0, 100, 0, 0.5); border: 1px solid #00ff00; padding: 1rem; margin-bottom: 1rem;">
            ✓ User successfully created with temporary password
        </div>
        {% elif request.query_params.get('success') == 'deleted' %}
        <div style="background: rgba(100, 0, 0, 0.5); border: 1px solid #ff0000; padding: 1rem; margin-bottom: 1rem;">
            ✓ User successfully deleted
        </div>
        {% elif request.query_params.get('error') %}
        <div class="warning-box">
            <p>Error: {{ request.query_params.get('error') }}</p>
        </div>
        {% endif %}

        <p style="margin-bottom: 2rem; opacity: 0.8;">
            Manage user access to different areas by adding or removing them from groups.
        </p>

        <div class="info-section">
            <h3>AVAILABLE GROUPS</h3>
            <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-top: 1rem;">
                {% for group in all_groups %}
                <span class="badge">{{ group }}</span>
                {% endfor %}
            </div>
        </div>

        <h3 style="color: #00ff00; margin-top: 2rem; margin-bottom: 1rem;">USER DIRECTORY</h3>

        <div style="margin-bottom: 1rem;">
            <button onclick="showCreateUserModal()"
                    style="background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.8rem 1.5rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-size: 0.85rem; font-weight: 700; text-transform: uppercase;">
                + CREATE NEW USER
            </button>
        </div>

        <table style="width: 100%; margin-top: 1rem;">
            <thead>
                <tr>
                    <th>EMAIL</th>
                    <th>CURRENT GROUPS</th>
                    <th>ACTIONS</th>
                </tr>
            </thead>
            <tbody>
                {% for user in users %}
                <tr>
                    <td>{{ user.email }}</td>
                    <td>
                        {% if user.groups %}
                            {% for group in user.groups %}
                            <span class="badge" style="font-size: 0.75rem; padding: 0.2rem 0.6rem;">{{ group }}</span>
                            {% endfor %}
                        {% else %}
                            <span style="opacity: 0.5;">No groups</span>
                        {% endif %}
                    </td>
                    <td>
                        <button onclick="showAddGroupModal('{{ user.username }}', '{{ user.email }}')"
                                style="background: rgba(0, 255, 0, 0.1); border: 1px solid #00ff00; color: #00ff00; padding: 0.4rem 0.8rem; cursor: pointer; margin-right: 0.5rem; font-family: 'Source Code Pro', monospace; font-size: 0.75rem;">
                            + ADD
                        </button>
                        {% if user.groups %}
                        <button onclick="showRemoveGroupModal('{{ user.username }}', '{{ user.email }}', {{ user.groups|tojson }})"
                                style="background: rgba(255, 0, 0, 0.1); border: 1px solid #ff0000; color: #ff0000; padding: 0.4rem 0.8rem; cursor: pointer; margin-right: 0.5rem; font-family: 'Source Code Pro', monospace; font-size: 0.75rem;">
                            - REMOVE
                        </button>
                        {% endif %}
                        <button onclick="showDeleteUserModal('{{ user.username }}', '{{ user.email }}')"
                                style="background: rgba(255, 0, 0, 0.2); border: 1px solid #ff0000; color: #ff0000; padding: 0.4rem 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-size: 0.75rem;">
                            🗑 DELETE
                        </button>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>

        <div class="nav-links" style="margin-top: 3rem;">
            <a href="/">← RETURN TO HOME</a>
        </div>
    </div>
</div>

<!-- Add Group Modal -->
<div id="addGroupModal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; align-items: center; justify-content: center;">
    <div style="background: #000; border: 2px solid #00ff00; padding: 2rem; max-width: 500px; box-shadow: 0 0 30px rgba(0, 255, 0, 0.5);">
        <h3 style="color: #00ff00; margin-bottom: 1rem;">ADD USER TO GROUP</h3>
        <p style="margin-bottom: 1rem;"><strong>User:</strong> <span id="addUserEmail"></span></p>
        <form method="POST" action="/admin/add-user-to-group">
            <input type="hidden" name="username" id="addUsername">
            <div style="margin-bottom: 1rem;">
                <label style="display: block; margin-bottom: 0.5rem;">Select Group:</label>
                <select name="group_name" required style="width: 100%; padding: 0.5rem; background: #000; border: 1px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace;">
                    {% for group in all_groups %}
                    <option value="{{ group }}">{{ group }}</option>
                    {% endfor %}
                </select>
            </div>
            <div style="display: flex; gap: 1rem;">
                <button type="submit" class="btn-primary" style="flex: 1;">ADD TO GROUP</button>
                <button type="button" onclick="closeAddGroupModal()" class="btn-secondary" style="flex: 1;">CANCEL</button>
            </div>
        </form>
    </div>
</div>

<!-- Remove Group Modal -->
<div id="removeGroupModal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; align-items: center; justify-content: center;">
    <div style="background: #000; border: 2px solid #ff0000; padding: 2rem; max-width: 500px; box-shadow: 0 0 30px rgba(255, 0, 0, 0.5);">
        <h3 style="color: #ff0000; margin-bottom: 1rem;">REMOVE USER FROM GROUP</h3>
        <p style="margin-bottom: 1rem;"><strong>User:</strong> <span id="removeUserEmail"></span></p>
        <form method="POST" action="/admin/remove-user-from-group">
            <input type="hidden" name="username" id="removeUsername">
            <div style="margin-bottom: 1rem;">
                <label style="display: block; margin-bottom: 0.5rem;">Select Group to Remove:</label>
                <select name="group_name" id="removeGroupSelect" required style="width: 100%; padding: 0.5rem; background: #000; border: 1px solid #ff0000; color: #ff0000; font-family: 'Source Code Pro', monospace;">
                </select>
            </div>
            <div style="display: flex; gap: 1rem;">
                <button type="submit" style="flex: 1; background: rgba(255, 0, 0, 0.2); border: 2px solid #ff0000; color: #ff0000; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">REMOVE FROM GROUP</button>
                <button type="button" onclick="closeRemoveGroupModal()" class="btn-secondary" style="flex: 1;">CANCEL</button>
            </div>
        </form>
    </div>
</div>

<!-- Create User Modal -->
<div id="createUserModal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; align-items: center; justify-content: center;">
    <div style="background: #000; border: 2px solid #00ff00; padding: 2rem; max-width: 500px; box-shadow: 0 0 30px rgba(0, 255, 0, 0.5);">
        <h3 style="color: #00ff00; margin-bottom: 1rem;">CREATE NEW USER</h3>
        <form method="POST" action="/admin/create-user">
            <div style="margin-bottom: 1rem;">
                <label style="display: block; margin-bottom: 0.5rem;">Email Address:</label>
                <input type="email" name="email" required style="width: 100%; padding: 0.5rem; background: #000; border: 1px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace;">
            </div>
            <div style="margin-bottom: 1rem;">
                <label style="display: block; margin-bottom: 0.5rem;">Temporary Password:</label>
                <input type="text" name="temp_password" value="TempPass123!" required style="width: 100%; padding: 0.5rem; background: #000; border: 1px solid #00ff00; color: #00ff00; font-family: 'Source Code Pro', monospace;">
                <p style="font-size: 0.8rem; opacity: 0.7; margin-top: 0.5rem;">User must change password on first login</p>
            </div>
            <div style="display: flex; gap: 1rem;">
                <button type="submit" class="btn-primary" style="flex: 1;">CREATE USER</button>
                <button type="button" onclick="closeCreateUserModal()" class="btn-secondary" style="flex: 1;">CANCEL</button>
            </div>
        </form>
    </div>
</div>

<!-- Delete User Modal -->
<div id="deleteUserModal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; align-items: center; justify-content: center;">
    <div style="background: #000; border: 2px solid #ff0000; padding: 2rem; max-width: 500px; box-shadow: 0 0 30px rgba(255, 0, 0, 0.5);">
        <h3 style="color: #ff0000; margin-bottom: 1rem;">⚠ DELETE USER</h3>
        <p style="margin-bottom: 1rem;">Are you sure you want to delete this user?</p>
        <p style="margin-bottom: 1rem;"><strong>User:</strong> <span id="deleteUserEmail"></span></p>
        <div class="warning-box" style="margin-bottom: 1rem;">
            <p style="font-size: 0.9rem;">This action cannot be undone. The user will be permanently removed from the system.</p>
        </div>
        <form method="POST" action="/admin/delete-user">
            <input type="hidden" name="username" id="deleteUsername">
            <div style="display: flex; gap: 1rem;">
                <button type="submit" style="flex: 1; background: rgba(255, 0, 0, 0.3); border: 2px solid #ff0000; color: #ff0000; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">DELETE USER</button>
                <button type="button" onclick="closeDeleteUserModal()" class="btn-secondary" style="flex: 1;">CANCEL</button>
            </div>
        </form>
    </div>
</div>

<script>
function showAddGroupModal(username, email) {
    document.getElementById('addUsername').value = username;
    document.getElementById('addUserEmail').textContent = email;
    document.getElementById('addGroupModal').style.display = 'flex';
}

function closeAddGroupModal() {
    document.getElementById('addGroupModal').style.display = 'none';
}

function showRemoveGroupModal(username, email, groups) {
    document.getElementById('removeUsername').value = username;
    document.getElementById('removeUserEmail').textContent = email;

    const select = document.getElementById('removeGroupSelect');
    while (select.firstChild) {
        select.removeChild(select.firstChild);
    }

    groups.forEach(group => {
        const option = document.createElement('option');
        option.value = group;
        option.textContent = group;
        select.appendChild(option);
    });

    document.getElementById('removeGroupModal').style.display = 'flex';
}

function closeRemoveGroupModal() {
    document.getElementById('removeGroupModal').style.display = 'none';
}

function showCreateUserModal() {
    document.getElementById('createUserModal').style.display = 'flex';
}

function closeCreateUserModal() {
    document.getElementById('createUserModal').style.display = 'none';
}

function showDeleteUserModal(username, email) {
    document.getElementById('deleteUsername').value = username;
    document.getElementById('deleteUserEmail').textContent = email;
    document.getElementById('deleteUserModal').style.display = 'flex';
}

function closeDeleteUserModal() {
    document.getElementById('deleteUserModal').style.display = 'none';
}

// Close modal when clicking outside
document.getElementById('addGroupModal').addEventListener('click', function(e) {
    if (e.target === this) closeAddGroupModal();
});
document.getElementById('removeGroupModal').addEventListener('click', function(e) {
    if (e.target === this) closeRemoveGroupModal();
});
document.getElementById('createUserModal').addEventListener('click', function(e) {
    if (e.target === this) closeCreateUserModal();
});
document.getElementById('deleteUserModal').addEventListener('click', function(e) {
    if (e.target === this) closeDeleteUserModal();
});

// Force hard reload on success to bypass browser cache
window.addEventListener('DOMContentLoaded', function() {
    const urlParams = new URLSearchParams(window.location.search);
    const timestamp = urlParams.get('t');
    const success = urlParams.get('success');

    // If we just redirected with a timestamp, clean it from URL and force reload once
    if (timestamp && success && !sessionStorage.getItem('admin_reloaded_' + timestamp)) {
        sessionStorage.setItem('admin_reloaded_' + timestamp, 'true');
        // Remove timestamp from URL and reload
        window.location.href = '/admin?success=' + success;
    }

    // Clean up old reload markers (keep last 10)
    for (let i = 0; i < sessionStorage.length; i++) {
        const key = sessionStorage.key(i);
        if (key && key.startsWith('admin_reloaded_')) {
            const ts = parseInt(key.replace('admin_reloaded_', ''));
            const now = Math.floor(Date.now() / 1000);
            if (now - ts > 300) { // older than 5 minutes
                sessionStorage.removeItem(key);
            }
        }
    }
});
</script>
{% endblock %}
EOFADMIN

# Create EC2 Resources template
cat > /opt/employee-portal/templates/ec2_resources.html << 'EOFEC2'
{% extends "base.html" %}

{% block title %}EC2 RESOURCES - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
 _____ ____ ____    ____  _____ ____   ___  _   _ ____   ____ _____ ____
| ____/ ___|___ \  |  _ \| ____/ ___| / _ \| | | |  _ \ / ___| ____/ ___|
|  _|| |     __) | | |_) |  _| \___ \| | | | | | | |_) | |   |  _| \___ \
| |__| |___ / __/  |  _ <| |___ ___) | |_| | |_| |  _ <| |___| |___ ___) |
|_____\____|_____| |_| \_\_____|____/ \___/ \___/|_| \_\\____|_____|____/

 EC2 INSTANCE MANAGEMENT
    </pre>

    <div class="content-box">
        <h2>⚡ EC2 RESOURCES MANAGEMENT</h2>

        <div id="status-message" style="display: none; padding: 1rem; margin-bottom: 1rem; border: 1px solid;"></div>

        <p style="margin-bottom: 2rem; opacity: 0.8;">
            Manage EC2 instances mapped to portal tabs. Instances tagged with "VibeCodeArea" will redirect users to SSM Session Manager.
        </p>

        <div style="margin-bottom: 2rem;">
            <button onclick="showAddInstanceModal()"
                    style="background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.8rem 1.5rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-size: 0.85rem; font-weight: 700; text-transform: uppercase; margin-right: 1rem;">
                + ADD INSTANCE
            </button>
            <button onclick="refreshInstances()"
                    style="background: rgba(0, 100, 255, 0.2); border: 2px solid #00aaff; color: #00aaff; padding: 0.8rem 1.5rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-size: 0.85rem; font-weight: 700; text-transform: uppercase;">
                ↻ REFRESH
            </button>
        </div>

        <h3 style="color: #00ff00; margin-top: 2rem; margin-bottom: 1rem;">MANAGED INSTANCES</h3>

        <div id="loading" style="text-align: center; padding: 2rem; color: #00ff00;">
            Loading instances...
        </div>

        <table id="instances-table" style="width: 100%; margin-top: 1rem; display: none;">
            <thead>
                <tr>
                    <th>NAME</th>
                    <th>INSTANCE ID</th>
                    <th>TYPE</th>
                    <th>PUBLIC IP</th>
                    <th>PRIVATE IP</th>
                    <th>AREA</th>
                    <th>STATE</th>
                </tr>
            </thead>
            <tbody id="instances-tbody">
            </tbody>
        </table>

        <div id="no-instances" style="display: none; text-align: center; padding: 2rem; color: rgba(0, 255, 0, 0.5);">
            No instances found. Add instances using the button above.
        </div>
    </div>
</div>

<!-- Add Instance Modal -->
<div id="add-instance-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; justify-content: center; align-items: center;">
    <div style="background: rgba(0, 20, 0, 0.95); border: 2px solid #00ff00; padding: 2rem; max-width: 500px; width: 90%; box-shadow: 0 0 30px rgba(0, 255, 0, 0.5);">
        <h3 style="color: #00ff00; margin-bottom: 1.5rem;">ADD EC2 INSTANCE</h3>

        <div style="margin-bottom: 1rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Instance ID:</label>
            <input type="text" id="instance-id-input" placeholder="i-0123456789abcdef0"
                   style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
        </div>

        <div style="margin-bottom: 1.5rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Map to Area:</label>
            <select id="area-select"
                    style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
                <option value="">-- Select Area --</option>
                <option value="engineering">Engineering</option>
                <option value="hr">HR</option>
                <option value="product">Product</option>
            </select>
        </div>

        <div style="display: flex; gap: 1rem;">
            <button onclick="addInstance()"
                    style="flex: 1; background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                ADD
            </button>
            <button onclick="closeModal()"
                    style="flex: 1; background: rgba(255, 0, 0, 0.2); border: 2px solid #ff0000; color: #ff0000; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                CANCEL
            </button>
        </div>
    </div>
</div>

<script>
// Fetch and display instances
async function refreshInstances() {
    document.getElementById('loading').style.display = 'block';
    document.getElementById('instances-table').style.display = 'none';
    document.getElementById('no-instances').style.display = 'none';

    try {
        const response = await fetch('/api/ec2/instances');
        const data = await response.json();

        if (data.instances && data.instances.length > 0) {
            displayInstances(data.instances);
        } else {
            document.getElementById('loading').style.display = 'none';
            document.getElementById('no-instances').style.display = 'block';
        }
    } catch (error) {
        console.error('Error fetching instances:', error);
        showStatus('Error fetching instances: ' + error.message, 'error');
        document.getElementById('loading').style.display = 'none';
    }
}

function displayInstances(instances) {
    const tbody = document.getElementById('instances-tbody');
    tbody.innerHTML = '';

    instances.forEach(instance => {
        const row = document.createElement('tr');

        const stateColor = instance.state === 'running' ? '#00ff00' :
                          instance.state === 'stopped' ? '#ffaa00' : '#ff0000';

        // Create cells safely without innerHTML
        const nameCell = document.createElement('td');
        nameCell.textContent = instance.name;
        row.appendChild(nameCell);

        const idCell = document.createElement('td');
        idCell.textContent = instance.instance_id;
        row.appendChild(idCell);

        const typeCell = document.createElement('td');
        typeCell.textContent = instance.instance_type;
        row.appendChild(typeCell);

        const publicIpCell = document.createElement('td');
        publicIpCell.textContent = instance.public_ip;
        row.appendChild(publicIpCell);

        const privateIpCell = document.createElement('td');
        privateIpCell.textContent = instance.private_ip;
        row.appendChild(privateIpCell);

        const areaCell = document.createElement('td');
        const areaBadge = document.createElement('span');
        areaBadge.className = 'badge';
        areaBadge.textContent = instance.area;
        areaCell.appendChild(areaBadge);
        row.appendChild(areaCell);

        const stateCell = document.createElement('td');
        stateCell.textContent = instance.state.toUpperCase();
        stateCell.style.color = stateColor;
        row.appendChild(stateCell);

        tbody.appendChild(row);
    });

    document.getElementById('loading').style.display = 'none';
    document.getElementById('instances-table').style.display = 'table';
}

function showAddInstanceModal() {
    document.getElementById('add-instance-modal').style.display = 'flex';
}

function closeModal() {
    document.getElementById('add-instance-modal').style.display = 'none';
    document.getElementById('instance-id-input').value = '';
    document.getElementById('area-select').value = '';
}

async function addInstance() {
    const instanceId = document.getElementById('instance-id-input').value.trim();
    const area = document.getElementById('area-select').value;

    if (!instanceId || !area) {
        showStatus('Please provide both Instance ID and Area', 'error');
        return;
    }

    try {
        const response = await fetch('/api/ec2/tag-instance', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                instance_id: instanceId,
                area: area
            })
        });

        const data = await response.json();

        if (data.success) {
            showStatus(data.message, 'success');
            closeModal();
            refreshInstances();
        } else {
            showStatus(data.message, 'error');
        }
    } catch (error) {
        showStatus('Error adding instance: ' + error.message, 'error');
    }
}

function showStatus(message, type) {
    const statusDiv = document.getElementById('status-message');
    statusDiv.textContent = message;
    statusDiv.style.display = 'block';

    if (type === 'success') {
        statusDiv.style.background = 'rgba(0, 100, 0, 0.5)';
        statusDiv.style.borderColor = '#00ff00';
        statusDiv.style.color = '#00ff00';
    } else {
        statusDiv.style.background = 'rgba(100, 0, 0, 0.5)';
        statusDiv.style.borderColor = '#ff0000';
        statusDiv.style.color = '#ff0000';
    }

    setTimeout(() => {
        statusDiv.style.display = 'none';
    }, 5000);
}

// Load instances on page load
refreshInstances();
</script>
{% endblock %}
EOFEC2

# Create password reset custom flow template
cat > /opt/employee-portal/templates/password_reset.html << 'EOFRESETFLOW'
{% extends "base.html" %}

{% block title %}RESET PASSWORD - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
 ██████╗ ███████╗███████╗███████╗████████╗
 ██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝
 ██████╔╝█████╗  ███████╗█████╗     ██║
 ██╔══██╗██╔══╝  ╚════██║██╔══╝     ██║
 ██║  ██║███████╗███████║███████╗   ██║
 ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝   ╚═╝

 ██████╗  █████╗ ███████╗███████╗██╗    ██╗ ██████╗ ██████╗ ██████╗
 ██╔══██╗██╔══██╗██╔════╝██╔════╝██║    ██║██╔═══██╗██╔══██╗██╔══██╗
 ██████╔╝███████║███████╗███████╗██║ █╗ ██║██║   ██║██████╔╝██║  ██║
 ██╔═══╝ ██╔══██║╚════██║╚════██║██║███╗██║██║   ██║██╔══██╗██║  ██║
 ██║     ██║  ██║███████║███████║╚███╔███╔╝╚██████╔╝██║  ██║██████╔╝
 ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝ ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝
    </pre>

    <div class="content-box">
        <h2>🔑 RESET YOUR PASSWORD</h2>

        <p style="opacity: 0.8; margin-bottom: 2rem;">Follow the steps below to reset your password securely.</p>

        <!-- STEP 1: EMAIL -->
        <div id="step-email" class="reset-step">
            <div class="step-header">
                <span class="step-number">STEP 1</span>
                <h3 style="display: inline; margin-left: 1rem;">ENTER YOUR EMAIL</h3>
                <span id="email-check" class="step-status" style="display: none;">✓</span>
            </div>

            <div class="step-content" id="email-content">
                <p style="margin-bottom: 1rem;">Enter the email address associated with your account.</p>

                <div id="email-error" class="error-message" style="display: none;"></div>

                <div class="form-group">
                    <label for="email-input">Email Address:</label>
                    <input type="email" id="email-input" class="form-control" placeholder="user@example.com" autocomplete="email" />
                </div>

                <button id="send-code-btn" class="btn-primary">
                    <span id="send-code-text">SEND RESET CODE</span>
                    <span id="send-code-loading" style="display: none;">⟳ SENDING...</span>
                </button>
            </div>
        </div>

        <!-- STEP 2: CODE -->
        <div id="step-code" class="reset-step" style="display: none;">
            <div class="step-header">
                <span class="step-number">STEP 2</span>
                <h3 style="display: inline; margin-left: 1rem;">ENTER VERIFICATION CODE</h3>
                <span id="code-check" class="step-status" style="display: none;">✓</span>
            </div>

            <div class="step-content" id="code-content">
                <div id="code-success" class="success-message" style="display: none;">
                    <strong>✓ Code sent!</strong> Check your email at <span id="code-destination"></span><br>
                    <span style="opacity: 0.8; font-size: 0.9rem;">Code is valid for 1 hour.</span>
                </div>

                <div id="code-error" class="error-message" style="display: none;"></div>

                <div class="form-group">
                    <label for="code-input">Verification Code (6 digits):</label>
                    <input type="text" id="code-input" class="form-control" placeholder="123456" maxlength="6" pattern="[0-9]{6}" autocomplete="off" />
                </div>

                <p style="font-size: 0.85rem; opacity: 0.7; margin-bottom: 1rem;">
                    Didn't receive the code?
                    <a href="#" id="resend-code-link" style="color: #00ff00; text-decoration: underline;">Resend</a>
                    <span id="resend-cooldown" style="display: none; color: #ffff00;"></span>
                </p>

                <button id="verify-code-btn" class="btn-primary">
                    <span id="verify-code-text">VERIFY CODE</span>
                    <span id="verify-code-loading" style="display: none;">⟳ VERIFYING...</span>
                </button>
            </div>
        </div>

        <!-- STEP 3: PASSWORD -->
        <div id="step-password" class="reset-step" style="display: none;">
            <div class="step-header">
                <span class="step-number">STEP 3</span>
                <h3 style="display: inline; margin-left: 1rem;">SET NEW PASSWORD</h3>
            </div>

            <div class="step-content" id="password-content">
                <div id="password-error" class="error-message" style="display: none;"></div>

                <div class="form-group">
                    <label for="password-input">New Password:</label>
                    <div style="position: relative;">
                        <input type="password" id="password-input" class="form-control" placeholder="Enter new password" autocomplete="new-password" />
                        <button type="button" id="toggle-password" style="position: absolute; right: 10px; top: 50%; transform: translateY(-50%); background: none; border: none; color: #00ff00; cursor: pointer; font-size: 1.2rem;">
                            👁
                        </button>
                    </div>
                </div>

                <div class="password-requirements" style="margin: 1rem 0; padding: 1rem; background: rgba(0, 20, 0, 0.5); border-left: 3px solid #00ff00;">
                    <p style="margin-bottom: 0.5rem; font-weight: bold;">Password Requirements:</p>
                    <ul style="list-style: none; padding: 0; margin: 0; font-size: 0.9rem;">
                        <li id="req-length" class="requirement">
                            <span class="req-icon">✗</span> Minimum 8 characters
                        </li>
                        <li id="req-uppercase" class="requirement">
                            <span class="req-icon">✗</span> At least one uppercase letter (A-Z)
                        </li>
                        <li id="req-lowercase" class="requirement">
                            <span class="req-icon">✗</span> At least one lowercase letter (a-z)
                        </li>
                        <li id="req-number" class="requirement">
                            <span class="req-icon">✗</span> At least one number (0-9)
                        </li>
                        <li id="req-special" class="requirement">
                            <span class="req-icon">✗</span> At least one special character (!@#$%^&*)
                        </li>
                    </ul>
                </div>

                <button id="reset-password-btn" class="btn-primary" disabled>
                    <span id="reset-password-text">RESET PASSWORD</span>
                    <span id="reset-password-loading" style="display: none;">⟳ RESETTING...</span>
                </button>
            </div>
        </div>

        <div class="nav-links" style="margin-top: 2rem;">
            <a href="/logout">← RETURN TO LOGIN</a>
        </div>
    </div>
</div>

<style>
.reset-step {
    margin-bottom: 2rem;
    opacity: 1;
    transition: opacity 0.3s ease;
}

.reset-step.completed {
    opacity: 0.6;
}

.reset-step.active {
    border: 2px solid #00ff00;
    padding: 1.5rem;
    background: rgba(0, 255, 0, 0.05);
    animation: glow 2s infinite;
}

@keyframes glow {
    0%, 100% { box-shadow: 0 0 10px rgba(0, 255, 0, 0.3); }
    50% { box-shadow: 0 0 20px rgba(0, 255, 0, 0.5); }
}

.step-header {
    margin-bottom: 1rem;
    display: flex;
    align-items: center;
}

.step-number {
    background: rgba(0, 255, 0, 0.2);
    border: 2px solid #00ff00;
    color: #00ff00;
    padding: 0.3rem 0.8rem;
    font-weight: bold;
    font-size: 0.85rem;
}

.step-status {
    color: #00ff00;
    font-size: 1.5rem;
    margin-left: auto;
}

.step-content {
    padding-left: 1rem;
}

.form-group {
    margin-bottom: 1.5rem;
}

.form-group label {
    display: block;
    margin-bottom: 0.5rem;
    color: #00ff00;
    font-weight: bold;
}

.form-control {
    width: 100%;
    padding: 0.8rem;
    background: rgba(0, 0, 0, 0.7);
    border: 2px solid #00ff00;
    color: #00ff00;
    font-family: 'Courier Prime', monospace;
    font-size: 1rem;
}

.form-control:focus {
    outline: none;
    box-shadow: 0 0 10px rgba(0, 255, 0, 0.5);
}

.error-message {
    background: rgba(255, 0, 0, 0.2);
    border: 2px solid #ff0000;
    color: #ff0000;
    padding: 1rem;
    margin-bottom: 1rem;
}

.success-message {
    background: rgba(0, 255, 0, 0.2);
    border: 2px solid #00ff00;
    color: #00ff00;
    padding: 1rem;
    margin-bottom: 1rem;
}

.requirement {
    margin: 0.3rem 0;
    transition: color 0.3s ease;
}

.requirement.met {
    color: #00ff00;
}

.requirement.met .req-icon {
    color: #00ff00;
}

.req-icon {
    display: inline-block;
    width: 1.5rem;
    color: #ff0000;
    font-weight: bold;
}
</style>

<script>
// State
let userEmail = '';
let verificationCode = '';
let resendCooldown = 0;
let resendInterval = null;

// Password requirements
const requirements = {
    length: { regex: /.{8,}/, id: 'req-length' },
    uppercase: { regex: /[A-Z]/, id: 'req-uppercase' },
    lowercase: { regex: /[a-z]/, id: 'req-lowercase' },
    number: { regex: /[0-9]/, id: 'req-number' },
    special: { regex: /[!@#$%^&*(),.?":{}|<>]/, id: 'req-special' }
};

// Elements
const emailInput = document.getElementById('email-input');
const sendCodeBtn = document.getElementById('send-code-btn');
const codeInput = document.getElementById('code-input');
const verifyCodeBtn = document.getElementById('verify-code-btn');
const passwordInput = document.getElementById('password-input');
const resetPasswordBtn = document.getElementById('reset-password-btn');
const togglePasswordBtn = document.getElementById('toggle-password');
const resendLink = document.getElementById('resend-code-link');

// STEP 1: Send Code
sendCodeBtn.addEventListener('click', async () => {
    const email = emailInput.value.trim().toLowerCase();

    if (!email) {
        showError('email-error', 'Please enter your email address');
        return;
    }

    // Basic email validation
    if (!email.includes('@')) {
        showError('email-error', 'Please enter a valid email address');
        return;
    }

    setLoading('send-code', true);
    hideError('email-error');

    try {
        const response = await fetch('/api/password-reset/send-code', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email })
        });

        const data = await response.json();

        if (data.success) {
            userEmail = email;
            document.getElementById('code-destination').textContent = data.destination;
            document.getElementById('code-success').style.display = 'block';

            // Complete step 1
            completeStep('email');
            revealStep('code');

            // Start resend cooldown
            startResendCooldown();
        } else {
            showError('email-error', data.message || 'Failed to send code');
        }
    } catch (error) {
        showError('email-error', 'Network error. Please try again.');
    } finally {
        setLoading('send-code', false);
    }
});

// STEP 2: Verify Code
verifyCodeBtn.addEventListener('click', async () => {
    const code = codeInput.value.trim();

    if (!code) {
        showError('code-error', 'Please enter the verification code');
        return;
    }

    if (code.length !== 6 || !/^\d+$/.test(code)) {
        showError('code-error', 'Code must be 6 digits');
        return;
    }

    setLoading('verify-code', true);
    hideError('code-error');

    try {
        const response = await fetch('/api/password-reset/verify-code', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ code })
        });

        const data = await response.json();

        if (data.success) {
            verificationCode = code;

            // Complete step 2
            completeStep('code');
            revealStep('password');

            // Focus password input
            passwordInput.focus();
        } else {
            showError('code-error', data.message || 'Invalid code');
        }
    } catch (error) {
        showError('code-error', 'Network error. Please try again.');
    } finally {
        setLoading('verify-code', false);
    }
});

// STEP 3: Reset Password
resetPasswordBtn.addEventListener('click', async () => {
    const password = passwordInput.value;

    if (!password) {
        showError('password-error', 'Please enter a new password');
        return;
    }

    if (!checkAllRequirements(password)) {
        showError('password-error', 'Password must meet all requirements');
        return;
    }

    setLoading('reset-password', true);
    hideError('password-error');

    try {
        const response = await fetch('/api/password-reset/confirm', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                email: userEmail,
                code: verificationCode,
                password: password
            })
        });

        const data = await response.json();

        if (data.success) {
            // Redirect to success page
            window.location.href = '/password-reset-success';
        } else {
            if (data.error === 'expired') {
                showError('password-error', data.message + ' <a href="#" onclick="location.reload()" style="color: #00ff00; text-decoration: underline;">Start over</a>');
            } else {
                showError('password-error', data.message || 'Failed to reset password');
            }
        }
    } catch (error) {
        showError('password-error', 'Network error. Please try again.');
    } finally {
        setLoading('reset-password', false);
    }
});

// Password requirement checking
passwordInput.addEventListener('input', () => {
    const password = passwordInput.value;
    let allMet = true;

    for (const [key, req] of Object.entries(requirements)) {
        const element = document.getElementById(req.id);
        const met = req.regex.test(password);

        if (met) {
            element.classList.add('met');
            element.querySelector('.req-icon').textContent = '✓';
        } else {
            element.classList.remove('met');
            element.querySelector('.req-icon').textContent = '✗';
            allMet = false;
        }
    }

    resetPasswordBtn.disabled = !allMet;
});

// Toggle password visibility
togglePasswordBtn.addEventListener('click', () => {
    if (passwordInput.type === 'password') {
        passwordInput.type = 'text';
        togglePasswordBtn.textContent = '👁';
    } else {
        passwordInput.type = 'password';
        togglePasswordBtn.textContent = '👁';
    }
});

// Resend code
resendLink.addEventListener('click', async (e) => {
    e.preventDefault();

    if (resendCooldown > 0) {
        return;
    }

    setLoading('send-code', true);

    try {
        const response = await fetch('/api/password-reset/send-code', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email: userEmail })
        });

        const data = await response.json();

        if (data.success) {
            document.getElementById('code-success').style.display = 'block';
            document.getElementById('code-destination').textContent = data.destination;
            startResendCooldown();
            hideError('code-error');
        } else {
            showError('code-error', data.message || 'Failed to resend code');
        }
    } catch (error) {
        showError('code-error', 'Network error. Please try again.');
    } finally {
        setLoading('send-code', false);
    }
});

// Helper functions
function completeStep(step) {
    const stepEl = document.getElementById(`step-${step}`);
    stepEl.classList.add('completed');
    stepEl.classList.remove('active');
    document.getElementById(`${step}-check`).style.display = 'inline';

    // Disable inputs
    const content = document.getElementById(`${step}-content`);
    const inputs = content.querySelectorAll('input, button');
    inputs.forEach(input => input.disabled = true);
}

function revealStep(step) {
    const stepEl = document.getElementById(`step-${step}`);
    stepEl.style.display = 'block';
    stepEl.classList.add('active');

    // Smooth scroll to step
    setTimeout(() => {
        stepEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }, 100);
}

function showError(errorId, message) {
    const errorEl = document.getElementById(errorId);
    errorEl.innerHTML = `<strong>Error:</strong> ${message}`;
    errorEl.style.display = 'block';
}

function hideError(errorId) {
    document.getElementById(errorId).style.display = 'none';
}

function setLoading(buttonPrefix, isLoading) {
    const textEl = document.getElementById(`${buttonPrefix}-text`);
    const loadingEl = document.getElementById(`${buttonPrefix}-loading`);
    const btnEl = document.getElementById(`${buttonPrefix}-btn`);

    if (isLoading) {
        textEl.style.display = 'none';
        loadingEl.style.display = 'inline';
        btnEl.disabled = true;
    } else {
        textEl.style.display = 'inline';
        loadingEl.style.display = 'none';
        btnEl.disabled = false;
    }
}

function checkAllRequirements(password) {
    return Object.values(requirements).every(req => req.regex.test(password));
}

function startResendCooldown() {
    resendCooldown = 60;
    resendLink.style.display = 'none';
    document.getElementById('resend-cooldown').style.display = 'inline';

    if (resendInterval) clearInterval(resendInterval);

    resendInterval = setInterval(() => {
        resendCooldown--;
        document.getElementById('resend-cooldown').textContent = `(Wait ${resendCooldown}s)`;

        if (resendCooldown <= 0) {
            clearInterval(resendInterval);
            resendLink.style.display = 'inline';
            document.getElementById('resend-cooldown').style.display = 'none';
        }
    }, 1000);
}

// Enable enter key on email input
emailInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') sendCodeBtn.click();
});

// Enable enter key on code input
codeInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') verifyCodeBtn.click();
});

// Enable enter key on password input
passwordInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter' && !resetPasswordBtn.disabled) resetPasswordBtn.click();
});
</script>
{% endblock %}
EOFRESETFLOW

# Create password reset success template
cat > /opt/employee-portal/templates/password_reset_success.html << 'EOFRESETSUCC'
{% extends "base.html" %}

{% block title %}PASSWORD RESET SUCCESSFUL - CAPSULE PORTAL{% endblock %}

{% block content %}
<div class="crt-container">
    <pre class="ascii-art">
 ███████╗██╗   ██╗ ██████╗ ██████╗███████╗███████╗███████╗██╗
 ██╔════╝██║   ██║██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝██║
 ███████╗██║   ██║██║     ██║     █████╗  ███████╗███████╗██║
 ╚════██║██║   ██║██║     ██║     ██╔══╝  ╚════██║╚════██║╚═╝
 ███████║╚██████╔╝╚██████╗╚██████╗███████╗███████║███████║██╗
 ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝╚══════╝╚══════╝╚══════╝╚═╝
    </pre>

    <div class="content-box">
        <div style="text-align: center; padding: 2rem 0;">
            <div style="font-size: 4rem; color: #00ff00; margin-bottom: 1rem;">✓</div>
            <h2 style="color: #00ff00; margin-bottom: 1rem;">PASSWORD RESET SUCCESSFUL!</h2>
        </div>

        <div class="info-section" style="background: rgba(0, 255, 0, 0.1); border: 2px solid #00ff00; padding: 2rem;">
            <p style="font-size: 1.1rem; margin-bottom: 1rem;">
                <strong>Your password has been reset successfully.</strong>
            </p>
            <p style="opacity: 0.9; margin-bottom: 1.5rem;">
                You can now log in with your new password.
            </p>
        </div>

        <div class="warning-box" style="margin-top: 2rem; background: rgba(255, 200, 0, 0.1); border: 2px solid #ffc107; padding: 2rem;">
            <h3 style="color: #ffc107; margin-bottom: 1rem;">⚠️ IMPORTANT - NEXT STEPS</h3>
            <p style="margin-bottom: 1rem;"><strong>Follow these steps carefully to avoid login errors:</strong></p>
            <ol style="margin-left: 2rem; line-height: 2; font-size: 0.95rem;">
                <li><strong>Click the "LOGIN WITH NEW PASSWORD" button below</strong><br>
                    <span style="opacity: 0.8; font-size: 0.85rem;">This will take you to the Cognito login page</span>
                </li>
                <li><strong>Enter your email and your NEW password</strong><br>
                    <span style="opacity: 0.8; font-size: 0.85rem;">Use the password you just created, not your old one</span>
                </li>
                <li><strong>Click "Sign in"</strong><br>
                    <span style="opacity: 0.8; font-size: 0.85rem;">You will be logged into the portal</span>
                </li>
            </ol>

            <div style="background: rgba(255, 0, 0, 0.2); border-left: 3px solid #ff0000; padding: 1rem; margin-top: 1.5rem;">
                <p style="color: #ff6b6b; font-weight: bold; margin-bottom: 0.5rem;">❌ DO NOT:</p>
                <ul style="margin-left: 2rem; font-size: 0.9rem; line-height: 1.8;">
                    <li>Click "Forgot your password?" on the login page (you just reset it!)</li>
                    <li>Use your browser's back button after clicking login</li>
                    <li>Try to bookmark or manually navigate to OAuth callback URLs</li>
                </ul>
            </div>
        </div>

        <div style="text-align: center; margin-top: 3rem;">
            <a href="/" class="btn-primary" style="display: inline-block; padding: 1rem 2rem; font-size: 1.1rem;">
                🔐 LOGIN WITH NEW PASSWORD
            </a>
            <p style="margin-top: 1rem; opacity: 0.7; font-size: 0.85rem;">
                This will take you to the login page where you'll enter your new password
            </p>
        </div>

        <div class="info-section" style="margin-top: 2rem;">
            <h3>💡 SECURITY TIPS</h3>
            <ul style="margin-left: 2rem; margin-top: 1rem; line-height: 1.8;">
                <li>Update your password manager with the new password</li>
                <li>Don't reuse this password on other websites</li>
                <li>Enable Multi-Factor Authentication (MFA) for extra security</li>
                <li>Never share your password with anyone</li>
            </ul>
        </div>

        <div class="nav-links" style="margin-top: 2rem;">
            <p style="text-align: center; opacity: 0.7; font-size: 0.9rem;">
                Having trouble? Contact your administrator for help.
            </p>
        </div>
    </div>
</div>
{% endblock %}
EOFRESETSUCC

# Set ownership
chown -R app:app /opt/employee-portal

# Create systemd service
cat > /etc/systemd/system/employee-portal.service << 'EOFSERVICE'
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
EOFSERVICE

# Enable and start service
systemctl daemon-reload
systemctl enable employee-portal
systemctl start employee-portal

echo "Employee Portal deployed successfully!"
