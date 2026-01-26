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
cat > /opt/employee-portal/app.py << 'EOFAPP'
import os
import json
import base64
import time
from typing import Optional
from datetime import datetime, timedelta
import boto3
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from jose import jwt

app = FastAPI()
templates = Jinja2Templates(directory="/opt/employee-portal/templates")

# Configuration
USER_POOL_ID = "${user_pool_id}"
AWS_REGION = "${aws_region}"

# Cognito client
cognito_client = boto3.client('cognito-idp', region_name=AWS_REGION)

# In-memory cache for group memberships
group_cache = {}
CACHE_TTL = 60  # seconds

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
    """Middleware to require authentication and return user email and groups."""
    email = extract_user_from_alb_header(request)
    if not email:
        raise HTTPException(status_code=401, detail="Not authenticated")

    groups = get_user_groups(email)
    return email, groups

def require_group(request: Request, required_group: str) -> tuple:
    """Middleware to require a specific group membership."""
    email, groups = require_auth(request)

    if required_group not in groups:
        return None, None  # Will redirect to denied page

    return email, groups

@app.get("/health")
async def health():
    """Health check endpoint (no auth required)."""
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}

@app.get("/logout")
async def logout():
    """Logout endpoint that redirects to Cognito logout."""
    logout_url = "https://employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com/logout?client_id=2hheaklvmfkpsm547p2nuab3r7&logout_uri=https://portal.capsule-playground.com/logged-out"
    return RedirectResponse(url=logout_url, status_code=302)

@app.get("/logged-out", response_class=HTMLResponse)
async def logged_out(request: Request):
    """Logged out confirmation page (no auth required)."""
    response = templates.TemplateResponse("logged_out.html", {
        "request": request
    })
    # Clear all ALB authentication cookies with various attempts
    cookie_names = [
        "AWSELBAuthSessionCookie",
        "AWSELBAuthSessionCookie-0",
        "AWSELBAuthSessionCookie-1",
        "AWSELBAuthSessionCookie-2"
    ]
    for cookie_name in cookie_names:
        # Delete with various domain combinations
        response.delete_cookie(cookie_name, path="/", domain="portal.capsule-playground.com")
        response.delete_cookie(cookie_name, path="/", domain=".capsule-playground.com")
        response.delete_cookie(cookie_name, path="/")
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
    """Directory page showing user registry."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("directory.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "users": USER_REGISTRY
    })

@app.get("/areas/engineering", response_class=HTMLResponse)
async def area_engineering(request: Request):
    """Engineering area page."""
    email, groups = require_group(request, "engineering")

    if not email:
        return RedirectResponse(url="/denied")

    return templates.TemplateResponse("area.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "area_name": "Engineering",
        "area_description": "Welcome to the Engineering area. Access to technical resources and documentation."
    })

@app.get("/areas/hr", response_class=HTMLResponse)
async def area_hr(request: Request):
    """HR area page."""
    email, groups = require_group(request, "hr")

    if not email:
        return RedirectResponse(url="/denied")

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
    """Product area page."""
    email, groups = require_group(request, "product")

    if not email:
        return RedirectResponse(url="/denied")

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
    """MFA setup page - directs users to set up TOTP MFA."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("mfa_setup.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "cognito_domain": "employee-portal-gdg66a7d.auth.us-east-1.amazoncognito.com"
    })

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
        <a href="/mfa-setup" class="area-link" style="background: #8b008b; border-color: #ff00ff;">🔐 Set Up MFA</a>
        <a href="/password-reset-info" class="area-link" style="background: #006400; border-color: #00ff00;">🔑 Reset Password</a>
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
    <h2>Employee Directory</h2>
    <p>This directory shows all registered users and their assigned areas.</p>

    <table>
        <thead>
            <tr>
                <th>Email</th>
                <th>Assigned Areas</th>
            </tr>
        </thead>
        <tbody>
            {% for user in users %}
            <tr>
                <td>{{ user.email }}</td>
                <td>{{ user.areas }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>
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
        function clearAndReturn() {
            // Clear all cookies
            document.cookie.split(";").forEach(function(c) {
                var eqPos = c.indexOf("=");
                var name = eqPos > -1 ? c.substr(0, eqPos) : c;
                document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;";
                document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.capsule-playground.com";
                document.cookie = name + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=portal.capsule-playground.com";
            });

            // Clear storage
            localStorage.clear();
            sessionStorage.clear();

            // Force navigation to portal (ALB will require re-authentication)
            window.location.replace("https://portal.capsule-playground.com");
            return false;
        }
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

        <div class="info-section">
            <h3>HOW TO ENABLE MFA:</h3>
            <ol>
                <li>Download an authenticator app (Google Authenticator, Authy, Microsoft Authenticator)</li>
                <li>Log out of the portal</li>
                <li>Log back in - you'll be prompted to set up MFA during login</li>
                <li>Scan the QR code with your authenticator app</li>
                <li>Enter the 6-digit code to complete setup</li>
            </ol>
        </div>

        <div class="warning-box">
            <p>⚠ MFA must be configured during your next login through Cognito's authentication flow.</p>
            <p>This portal uses ALB authentication, so MFA setup happens at the AWS Cognito level.</p>
        </div>

        <div class="nav-links">
            <a href="/">← RETURN TO HOME</a>
        </div>
    </div>
</div>
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
