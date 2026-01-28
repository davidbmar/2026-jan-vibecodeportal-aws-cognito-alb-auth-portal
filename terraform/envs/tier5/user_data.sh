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
"""
CAPSULE Employee Portal - FastAPI Application
==============================================

ARCHITECTURE OVERVIEW:
----------------------
This portal uses AWS Cognito with ALB (Application Load Balancer) authentication.
The ALB handles OAuth2 login via Cognito Hosted UI, and forwards authenticated
requests with JWT tokens in headers.

AUTHENTICATION FLOW:
--------------------
1. User visits portal → ALB redirects to Cognito Hosted UI
2. User enters email → Cognito sends 6-digit verification code via email
3. User enters code → Cognito validates via Lambda (custom auth challenge)
4. Cognito issues JWT tokens → ALB forwards request to this app with tokens
5. App decodes JWT from x-amzn-oidc-data header → extracts email and groups

EMAIL MFA (Passwordless Authentication):
-----------------------------------------
- Implemented via Cognito custom auth Lambda triggers (see lambdas/ directory)
- create_auth_challenge.py: Generates 6-digit code, stores in DynamoDB, sends via SES
- verify_auth_challenge.py: Validates code, deletes after use (single-use)
- No passwords required - users only need email access
- Legacy TOTP/QR code MFA has been completely removed

MAIN FEATURES:
--------------
- EC2 Instance Explorer (list, tag, filter instances)
- User Directory (view all portal users)
- Admin User Management (create/delete Cognito users)
- Settings page (account info, timezone selector)
- Custom password reset flow (logout → Cognito forgot password)

DEPLOYMENT:
-----------
- Deployed as systemd service: employee-portal.service
- Runs on port 8000 behind ALB on port 443
- Auto-deployed via EC2 user_data bootstrap script
"""

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

# ============================================================================
# CONFIGURATION
# ============================================================================
# These values are injected by Terraform during EC2 instance bootstrap
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

# ============================================================================
# EC2 INSTANCE LAUNCH HELPERS
# ============================================================================

def get_instance_metadata(path: str) -> Optional[str]:
    """
    Query EC2 metadata service (IMDSv2) for current instance info.

    Uses IMDSv2 token-based access for secure metadata retrieval.
    Common paths: instance-id, local-ipv4, placement/availability-zone

    Args:
        path: Metadata path to query (e.g., 'instance-id', 'local-ipv4')

    Returns:
        str: Metadata value if found, None on error
    """
    import urllib.request
    import urllib.error

    try:
        # Step 1: Get IMDSv2 token
        token_request = urllib.request.Request(
            'http://169.254.169.254/latest/api/token',
            headers={'X-aws-ec2-metadata-token-ttl-seconds': '21600'},
            method='PUT'
        )
        token = urllib.request.urlopen(token_request, timeout=2).read().decode('utf-8')

        # Step 2: Query metadata using token
        metadata_request = urllib.request.Request(
            f'http://169.254.169.254/latest/meta-data/{path}',
            headers={'X-aws-ec2-metadata-token': token}
        )
        return urllib.request.urlopen(metadata_request, timeout=2).read().decode('utf-8')
    except Exception as e:
        print(f"Failed to query metadata {path}: {e}")
        return None


def get_current_instance_info() -> dict:
    """
    Get portal instance's VPC, subnet, private IP, and security groups.

    Combines metadata service queries with describe_instances API call
    to gather complete network configuration of the portal host.

    Returns:
        dict: {instance_id, private_ip, vpc_id, subnet_id, security_groups}
              Returns empty dict on error
    """
    try:
        # Query metadata service
        instance_id = get_instance_metadata('instance-id')
        private_ip = get_instance_metadata('local-ipv4')

        if not instance_id or not private_ip:
            print("Failed to get instance ID or private IP from metadata")
            return {}

        # Query EC2 API for VPC/subnet details
        response = ec2_client.describe_instances(InstanceIds=[instance_id])

        if not response['Reservations']:
            print(f"No reservation found for instance {instance_id}")
            return {}

        instance = response['Reservations'][0]['Instances'][0]

        return {
            'instance_id': instance_id,
            'private_ip': private_ip,
            'vpc_id': instance.get('VpcId'),
            'subnet_id': instance.get('SubnetId'),
            'security_groups': [sg['GroupId'] for sg in instance.get('SecurityGroups', [])]
        }
    except Exception as e:
        print(f"Failed to get current instance info: {e}")
        return {}


def get_latest_ubuntu_ami() -> Optional[str]:
    """
    Query latest Ubuntu 22.04 LTS AMI from Canonical.

    Searches for official Ubuntu Server 22.04 LTS (Jammy) AMIs from
    Canonical's AWS account (099720109477) and returns the most recent one.

    Returns:
        str: AMI ID (e.g., 'ami-0abc123def456') if found, None on error
    """
    try:
        response = ec2_client.describe_images(
            Owners=['099720109477'],  # Canonical's AWS account
            Filters=[
                {'Name': 'name', 'Values': ['ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*']},
                {'Name': 'state', 'Values': ['available']},
                {'Name': 'architecture', 'Values': ['x86_64']},
                {'Name': 'virtualization-type', 'Values': ['hvm']},
                {'Name': 'root-device-type', 'Values': ['ebs']}
            ]
        )

        if not response['Images']:
            print("No Ubuntu 22.04 LTS AMIs found")
            return None

        # Sort by creation date (newest first) and return the latest
        sorted_images = sorted(response['Images'], key=lambda x: x['CreationDate'], reverse=True)
        latest_ami = sorted_images[0]['ImageId']
        print(f"Found latest Ubuntu 22.04 AMI: {latest_ami} (created: {sorted_images[0]['CreationDate']})")
        return latest_ami

    except Exception as e:
        print(f"Failed to query Ubuntu AMI: {e}")
        return None


def generate_instance_name() -> str:
    """
    Generate unique instance name: 2026-01-jan-27-vibecode-instance-01

    Queries existing instances with today's date prefix to find the highest
    counter, then increments by 1. Falls back to timestamp if query fails.

    Returns:
        str: Unique instance name with format YYYY-MM-{month}-DD-vibecode-instance-{counter}
    """
    try:
        now = datetime.now()
        # Format: 2026-01-jan-27
        month_abbr = now.strftime('%b').lower()
        date_prefix = f"{now.year}-{now.month:02d}-{month_abbr}-{now.day:02d}-vibecode-instance"

        # Query instances with today's date prefix
        response = ec2_client.describe_instances(
            Filters=[
                {'Name': 'tag:Name', 'Values': [f"{date_prefix}-*"]},
                {'Name': 'instance-state-name', 'Values': ['pending', 'running', 'stopping', 'stopped']}
            ]
        )

        # Find highest counter
        max_counter = 0
        pattern = re.compile(rf"{re.escape(date_prefix)}-(\d+)")

        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                for tag in instance.get('Tags', []):
                    if tag['Key'] == 'Name':
                        match = pattern.match(tag['Value'])
                        if match:
                            counter = int(match.group(1))
                            max_counter = max(max_counter, counter)

        # Increment counter
        new_counter = max_counter + 1
        instance_name = f"{date_prefix}-{new_counter:02d}"
        print(f"Generated instance name: {instance_name}")
        return instance_name

    except Exception as e:
        # Fallback: use timestamp
        timestamp = int(time.time())
        fallback_name = f"{now.year}-{now.month:02d}-{month_abbr}-{now.day:02d}-vibecode-instance-{timestamp}"
        print(f"Failed to generate name from counters, using fallback: {fallback_name} (error: {e})")
        return fallback_name


def ensure_ssh_security_group(vpc_id: str, portal_private_ip: str) -> Optional[str]:
    """
    Create or reuse security group for launched instances.

    Creates a security group named 'vibecode-launched-instances' if it
    doesn't exist. Ensures proper ingress rules:
    - SSH (port 22): Restricted to portal host's private IP only
    - HTTP (port 80): Open to internet (0.0.0.0/0)
    - HTTPS (port 443): Open to internet (0.0.0.0/0)

    Args:
        vpc_id: VPC ID where security group should be created
        portal_private_ip: Portal host's private IP (e.g., '10.0.1.50')

    Returns:
        str: Security group ID if successful, None on error
    """
    sg_name = 'vibecode-launched-instances'
    sg_description = 'SSH from portal, HTTP/HTTPS from internet'

    try:
        # Check if security group already exists
        response = ec2_client.describe_security_groups(
            Filters=[
                {'Name': 'group-name', 'Values': [sg_name]},
                {'Name': 'vpc-id', 'Values': [vpc_id]}
            ]
        )

        if response['SecurityGroups']:
            sg_id = response['SecurityGroups'][0]['GroupId']
            print(f"Security group already exists: {sg_id}")

            # Verify required rules exist
            sg = response['SecurityGroups'][0]
            existing_rules = sg.get('IpPermissions', [])

            ssh_rule_exists = False
            http_rule_exists = False
            https_rule_exists = False

            for rule in existing_rules:
                if rule.get('IpProtocol') == 'tcp':
                    # Check SSH rule (port 22 from portal IP)
                    if rule.get('FromPort') == 22 and rule.get('ToPort') == 22:
                        for ip_range in rule.get('IpRanges', []):
                            if ip_range.get('CidrIp') == f"{portal_private_ip}/32":
                                ssh_rule_exists = True

                    # Check HTTP rule (port 80 from anywhere)
                    if rule.get('FromPort') == 80 and rule.get('ToPort') == 80:
                        for ip_range in rule.get('IpRanges', []):
                            if ip_range.get('CidrIp') == '0.0.0.0/0':
                                http_rule_exists = True

                    # Check HTTPS rule (port 443 from anywhere)
                    if rule.get('FromPort') == 443 and rule.get('ToPort') == 443:
                        for ip_range in rule.get('IpRanges', []):
                            if ip_range.get('CidrIp') == '0.0.0.0/0':
                                https_rule_exists = True

            # Add missing rules
            rules_to_add = []

            if not ssh_rule_exists:
                print(f"Adding SSH rule for {portal_private_ip}/32")
                rules_to_add.append({
                    'IpProtocol': 'tcp',
                    'FromPort': 22,
                    'ToPort': 22,
                    'IpRanges': [{'CidrIp': f"{portal_private_ip}/32", 'Description': 'SSH from portal host'}]
                })

            if not http_rule_exists:
                print("Adding HTTP rule for 0.0.0.0/0")
                rules_to_add.append({
                    'IpProtocol': 'tcp',
                    'FromPort': 80,
                    'ToPort': 80,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0', 'Description': 'HTTP from internet'}]
                })

            if not https_rule_exists:
                print("Adding HTTPS rule for 0.0.0.0/0")
                rules_to_add.append({
                    'IpProtocol': 'tcp',
                    'FromPort': 443,
                    'ToPort': 443,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0', 'Description': 'HTTPS from internet'}]
                })

            if rules_to_add:
                ec2_client.authorize_security_group_ingress(
                    GroupId=sg_id,
                    IpPermissions=rules_to_add
                )

            return sg_id

        # Create new security group
        print(f"Creating security group: {sg_name}")
        create_response = ec2_client.create_security_group(
            GroupName=sg_name,
            Description=sg_description,
            VpcId=vpc_id,
            TagSpecifications=[{
                'ResourceType': 'security-group',
                'Tags': [
                    {'Key': 'Name', 'Value': sg_name},
                    {'Key': 'ManagedBy', 'Value': 'vibecode-portal'}
                ]
            }]
        )

        sg_id = create_response['GroupId']
        print(f"Created security group: {sg_id}")

        # Add all ingress rules
        ec2_client.authorize_security_group_ingress(
            GroupId=sg_id,
            IpPermissions=[
                {
                    'IpProtocol': 'tcp',
                    'FromPort': 22,
                    'ToPort': 22,
                    'IpRanges': [{'CidrIp': f"{portal_private_ip}/32", 'Description': 'SSH from portal host'}]
                },
                {
                    'IpProtocol': 'tcp',
                    'FromPort': 80,
                    'ToPort': 80,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0', 'Description': 'HTTP from internet'}]
                },
                {
                    'IpProtocol': 'tcp',
                    'FromPort': 443,
                    'ToPort': 443,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0', 'Description': 'HTTPS from internet'}]
                }
            ]
        )

        print(f"Added SSH, HTTP, and HTTPS rules")
        return sg_id

    except Exception as e:
        print(f"Failed to ensure security group: {e}")
        return None


def launch_ec2_instance(instance_type: str, area: str) -> tuple:
    """
    Launch EC2 instance with full configuration and atomic tagging.

    Orchestrates the entire launch process: validation, metadata gathering,
    AMI lookup, name generation, security group setup, and instance creation
    with atomic tag application using TagSpecifications.

    Args:
        instance_type: EC2 instance type (e.g., 't3.micro', 't3.small')
        area: VibeCodeArea tag value (e.g., 'engineering', 'hr')

    Returns:
        tuple: (success: bool, message: str, result_data: dict)
               result_data contains {instance_id, name, private_ip, type, area}
    """
    # Validate inputs
    valid_instance_types = ['t3.micro', 't3.small', 't3.medium', 't3.large', 'm7i.large']
    if not instance_type or instance_type not in valid_instance_types:
        return (False, f"Invalid instance type. Must be one of: {', '.join(valid_instance_types)}", {})

    if not area or not area.strip():
        return (False, "VibeCodeArea tag is required", {})

    area = area.strip()

    try:
        # Step 1: Get portal instance metadata
        print("Getting portal instance metadata...")
        portal_info = get_current_instance_info()
        if not portal_info:
            return (False, "Failed to get portal instance network information", {})

        vpc_id = portal_info.get('vpc_id')
        subnet_id = portal_info.get('subnet_id')
        portal_ip = portal_info.get('private_ip')

        if not all([vpc_id, subnet_id, portal_ip]):
            return (False, "Incomplete portal network information (missing VPC/subnet/IP)", {})

        print(f"Portal info: VPC={vpc_id}, Subnet={subnet_id}, IP={portal_ip}")

        # Step 2: Get latest Ubuntu 22.04 AMI
        print("Looking up latest Ubuntu 22.04 AMI...")
        ami_id = get_latest_ubuntu_ami()
        if not ami_id:
            return (False, "Failed to find Ubuntu 22.04 LTS AMI", {})

        # Step 3: Generate unique instance name
        print("Generating unique instance name...")
        instance_name = generate_instance_name()

        # Step 4: Ensure SSH security group exists
        print("Setting up SSH security group...")
        ssh_sg_id = ensure_ssh_security_group(vpc_id, portal_ip)
        if not ssh_sg_id:
            return (False, "Failed to create/configure SSH security group", {})

        # Step 5: Launch instance with atomic tagging
        print(f"Launching {instance_type} instance...")
        launch_response = ec2_client.run_instances(
            ImageId=ami_id,
            InstanceType=instance_type,
            KeyName='david-capsule-vibecode-2026-01-17',
            SubnetId=subnet_id,
            SecurityGroupIds=[ssh_sg_id],
            MinCount=1,
            MaxCount=1,
            TagSpecifications=[{
                'ResourceType': 'instance',
                'Tags': [
                    {'Key': 'Name', 'Value': instance_name},
                    {'Key': 'VibeCodeArea', 'Value': area},
                    {'Key': 'LaunchedBy', 'Value': 'vibecode-portal'},
                    {'Key': 'LaunchDate', 'Value': datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
                ]
            }]
        )

        instance_id = launch_response['Instances'][0]['InstanceId']
        print(f"Instance launched: {instance_id}")

        # Step 6: Wait briefly for IP assignment
        time.sleep(2)

        # Query instance to get private IP
        describe_response = ec2_client.describe_instances(InstanceIds=[instance_id])
        instance = describe_response['Reservations'][0]['Instances'][0]
        private_ip = instance.get('PrivateIpAddress', 'pending')

        result_data = {
            'instance_id': instance_id,
            'name': instance_name,
            'private_ip': private_ip,
            'type': instance_type,
            'area': area
        }

        success_message = f"Successfully launched instance {instance_name} ({instance_id})"
        print(success_message)
        return (True, success_message, result_data)

    except Exception as e:
        error_message = f"Failed to launch instance: {str(e)}"
        print(error_message)
        return (False, error_message, {})

# ============================================================================
# EMAIL MFA CONFIGURATION
# ============================================================================
# Email-based MFA is handled by Cognito custom auth Lambda triggers.
# When users sign in, they receive a 6-digit code via email.
# See: lambdas/create_auth_challenge.py, verify_auth_challenge.py
# Legacy TOTP/QR code MFA has been removed in favor of this passwordless approach.

# ============================================================================
# USER REGISTRY
# ============================================================================
# Hardcoded user registry for directory page
USER_REGISTRY = [
    {"email": "dmar@capsule.com", "areas": "engineering, admins"},
    {"email": "jahn@capsule.com", "areas": "engineering"},
    {"email": "ahatcher@capsule.com", "areas": "hr"},
    {"email": "peter@capsule.com", "areas": "automation"},
    {"email": "sdedakia@capsule.com", "areas": "product"},
]

# ============================================================================
# AUTHENTICATION & AUTHORIZATION HELPERS
# ============================================================================

def extract_user_from_alb_header(request: Request) -> Optional[str]:
    """
    Extract user email from ALB x-amzn-oidc-data JWT header.

    The ALB forwards authenticated requests with a JWT token containing user info.
    This function decodes the JWT payload (without verification, since ALB already
    verified it) and extracts the email address.

    Args:
        request: FastAPI request object with headers from ALB

    Returns:
        str: User email if found, None otherwise
    """
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

def get_client_ip(request: Request) -> str:
    """
    Extract real client IP address from request, accounting for ALB proxy.

    The ALB adds X-Forwarded-For header containing the actual client IP.
    Format: X-Forwarded-For: <client-ip>, <alb-ip>, <proxy-ip>, ...

    Args:
        request: FastAPI Request object

    Returns:
        str: Client IP address (e.g., "73.158.64.21") or "unknown" if not found
    """
    # Check X-Forwarded-For header (set by ALB)
    x_forwarded_for = request.headers.get("X-Forwarded-For")
    if x_forwarded_for:
        # Take the first IP in the list (the actual client)
        client_ip = x_forwarded_for.split(',')[0].strip()
        return client_ip

    # Fallback to request.client (won't work behind ALB but safe fallback)
    if request.client:
        return request.client.host

    return "unknown"

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

# ============================================================================
# COGNITO USER MANAGEMENT
# ============================================================================
# Functions for listing, creating, and deleting Cognito users.
# These are used by the admin interface at /admin.

def list_cognito_users() -> list:
    """
    List all users from Cognito user pool with their groups and last login.

    Queries Cognito for all users, fetches their groups, and attempts to determine
    last login time from auth events or user modification date.

    Returns:
        list: List of dict with keys: username, email, status, enabled, groups, last_login
    """
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
    """
    Create a new user in Cognito with email-only passwordless authentication.

    IMPORTANT: Uses MessageAction='SUPPRESS' to prevent Cognito from sending
    temporary password emails. This is critical for passwordless auth - users should
    only receive 6-digit verification codes during login, not temp passwords.

    The temporary password is generated but NOT sent to the user. It's set in Cognito
    to satisfy password requirements, but the user will never use it directly.

    Args:
        email: User's email address (used as username in Cognito)
        groups: Optional list of Cognito group names to add user to (e.g., ['admins'])

    Returns:
        tuple: (success: bool, message: str)
            - (True, "User created...") on success
            - (False, "Error: ...") on failure
    """
    try:
        # Normalize email to lowercase to prevent case sensitivity issues
        email = email.lower().strip()

        # Generate a temporary password (satisfies Cognito requirements, but never sent to user)
        import secrets
        import string
        temp_password = ''.join(secrets.choice(string.ascii_letters + string.digits + '!@#$%') for _ in range(12))
        temp_password = temp_password[:10] + 'Aa1!' + temp_password[10:]  # Ensure complexity

        # Create user with MessageAction='SUPPRESS' to prevent temporary password email
        # This ensures users ONLY receive 6-digit codes at login, not password emails
        cognito_client.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=email,
            UserAttributes=[
                {'Name': 'email', 'Value': email},
                {'Name': 'email_verified', 'Value': 'true'}
            ],
            TemporaryPassword=temp_password,
            MessageAction='SUPPRESS'  # CRITICAL: Prevents temp password email
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
            "",  # Empty key since we're not verifying signature
            options={
                "verify_signature": False,
                "verify_aud": False,  # Skip audience validation
                "verify_exp": True    # Still check expiration
            }
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

    # Extract and store client IP for whitelisting/audit purposes
    request.state.client_ip = get_client_ip(request)

    response = await call_next(request)
    return response

# ============================================================================
# PUBLIC ROUTES (No Authentication Required)
# ============================================================================

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
    # Normalize email to lowercase to prevent case sensitivity issues
    email = email.lower().strip()

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

        # Log successful login with IP for audit trail
        client_ip = get_client_ip(request)
        print(f"Successful login: {email} from IP {client_ip} at {datetime.utcnow().isoformat()}")

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

# ============================================================================
# AUTHENTICATED ROUTES (Require Login)
# ============================================================================

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

    # Get client IP from request state (set by middleware)
    client_ip = getattr(request.state, 'client_ip', 'unknown')

    return templates.TemplateResponse("home.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "allowed_areas": allowed_areas,
        "client_ip": client_ip
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

# ============================================================================
# ADMIN ROUTES (Require 'admins' Group Membership)
# ============================================================================

@app.get("/admin", response_class=HTMLResponse)
async def admin_panel(request: Request):
    """
    Admin panel for managing Cognito users and group memberships.

    Features:
    - List all Cognito users with their status and last login
    - Create new users (passwordless - no email sent)
    - Delete users from Cognito
    - Add/remove users from groups (admins, engineering, hr, etc.)
    """
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

        # Normalize email to lowercase to prevent case sensitivity issues
        user_email = user_email.lower().strip()

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

@app.post("/api/ec2/launch-instance")
async def launch_ec2_instance_api(request: Request):
    """API endpoint to launch a new EC2 instance (admin only)."""
    email, groups = require_auth(request)

    # Check if user is admin
    if 'admins' not in groups:
        raise HTTPException(status_code=403, detail="Admin access required")

    try:
        data = await request.json()
        instance_type = data.get("instance_type")
        area = data.get("area")

        if not instance_type:
            return {"success": False, "message": "Missing instance_type"}

        if not area:
            return {"success": False, "message": "Missing area"}

        success, message, result_data = launch_ec2_instance(instance_type, area)

        if success:
            return {"success": True, "message": message, "instance": result_data}
        else:
            return {"success": False, "message": message}

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

        <!-- Display client IP address -->
        <p style="margin-top: 1rem;">
            <strong>Your IP Address:</strong>
            <span style="font-family: 'Courier New', monospace; color: #00ff00; background: rgba(0, 255, 0, 0.1); padding: 0.2rem 0.5rem; border-radius: 4px;">{{ client_ip }}</span>
        </p>
        <p style="font-size: 0.85rem; color: rgba(0, 255, 0, 0.6); margin-top: 0.25rem;">
            This IP will be used for host access whitelisting
        </p>
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
<div id="add-instance-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.9); z-index: 1000; justify-content: center; align-items: center; overflow-y: auto;">
    <div style="background: rgba(0, 20, 0, 0.95); border: 2px solid #00ff00; padding: 2rem; max-width: 600px; width: 90%; box-shadow: 0 0 30px rgba(0, 255, 0, 0.5); margin: 2rem auto;">
        <h3 style="color: #00ff00; margin-bottom: 1.5rem;">LAUNCH NEW EC2 INSTANCE</h3>

        <div style="margin-bottom: 1rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Instance Type:</label>
            <select id="instance-type-select"
                    style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
                <option value="">-- Select Instance Type --</option>
                <option value="t3.micro">t3.micro (2 vCPU, 1 GB RAM)</option>
                <option value="t3.small">t3.small (2 vCPU, 2 GB RAM)</option>
                <option value="t3.medium">t3.medium (2 vCPU, 4 GB RAM)</option>
                <option value="t3.large">t3.large (2 vCPU, 8 GB RAM)</option>
                <option value="m7i.large">m7i.large (2 vCPU, 8 GB RAM)</option>
            </select>
        </div>

        <div style="margin-bottom: 1rem;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">VibeCodeArea Tag:</label>
            <select id="area-select" onchange="toggleCustomArea()"
                    style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
                <option value="">-- Select Area --</option>
                <option value="engineering">engineering</option>
                <option value="hr">hr</option>
                <option value="automation">automation</option>
                <option value="product">product</option>
                <option value="custom">Custom (type below)</option>
            </select>
        </div>

        <div id="custom-area-container" style="margin-bottom: 1rem; display: none;">
            <label style="display: block; margin-bottom: 0.5rem; color: #00ff00;">Custom Area Name:</label>
            <input type="text" id="custom-area-input" placeholder="e.g., finance, operations"
                   style="width: 100%; background: rgba(0, 0, 0, 0.5); border: 1px solid #00ff00; color: #00ff00; padding: 0.8rem; font-family: 'Source Code Pro', monospace;">
        </div>

        <div style="background: rgba(0, 100, 0, 0.3); border: 1px solid #00ff00; padding: 1rem; margin-bottom: 1.5rem; font-size: 0.85rem;">
            <div style="color: #00ff00; font-weight: 700; margin-bottom: 0.5rem;">INSTANCE CONFIGURATION:</div>
            <div style="color: #88ff88;">• OS: Ubuntu 22.04 LTS (latest AMI)</div>
            <div style="color: #88ff88;">• Key Pair: david-capsule-vibecode-2026-01-17</div>
            <div style="color: #88ff88;">• Network: Same VPC/subnet as portal</div>
            <div style="color: #88ff88;">• Ports: SSH (22) portal only, HTTP (80) + HTTPS (443) open</div>
            <div style="color: #88ff88;">• Auto-naming: YYYY-MM-mon-DD-vibecode-instance-##</div>
        </div>

        <div id="launch-loading" style="display: none; background: rgba(255, 255, 0, 0.2); border: 1px solid #ffff00; padding: 1rem; margin-bottom: 1rem; color: #ffff00; text-align: center;">
            Launching instance... This may take 30-60 seconds
        </div>

        <div id="launch-result" style="display: none; padding: 1rem; margin-bottom: 1rem; border-radius: 4px;"></div>

        <div style="display: flex; gap: 1rem;">
            <button id="launch-button" onclick="launchInstance()"
                    style="flex: 1; background: rgba(0, 255, 0, 0.2); border: 2px solid #00ff00; color: #00ff00; padding: 0.8rem; cursor: pointer; font-family: 'Source Code Pro', monospace; font-weight: 700; text-transform: uppercase;">
                LAUNCH
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

function toggleCustomArea() {
    const areaSelect = document.getElementById('area-select').value;
    const customContainer = document.getElementById('custom-area-container');

    if (areaSelect === 'custom') {
        customContainer.style.display = 'block';
    } else {
        customContainer.style.display = 'none';
    }
}

function closeModal() {
    document.getElementById('add-instance-modal').style.display = 'none';
    document.getElementById('instance-type-select').value = '';
    document.getElementById('area-select').value = '';
    document.getElementById('custom-area-input').value = '';
    document.getElementById('custom-area-container').style.display = 'none';
    document.getElementById('launch-loading').style.display = 'none';
    document.getElementById('launch-result').style.display = 'none';
    document.getElementById('launch-button').disabled = false;
}

async function launchInstance() {
    const instanceType = document.getElementById('instance-type-select').value;
    const areaSelect = document.getElementById('area-select').value;
    const customArea = document.getElementById('custom-area-input').value.trim();

    // Determine final area value
    let area = areaSelect;
    if (areaSelect === 'custom') {
        if (!customArea) {
            showStatus('Please enter a custom area name', 'error');
            return;
        }
        area = customArea;
    }

    // Validate inputs
    if (!instanceType) {
        showStatus('Please select an instance type', 'error');
        return;
    }

    if (!areaSelect) {
        showStatus('Please select an area', 'error');
        return;
    }

    // Show loading state
    const launchButton = document.getElementById('launch-button');
    const loadingDiv = document.getElementById('launch-loading');
    const resultDiv = document.getElementById('launch-result');

    launchButton.disabled = true;
    loadingDiv.style.display = 'block';
    resultDiv.style.display = 'none';

    try {
        const response = await fetch('/api/ec2/launch-instance', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                instance_type: instanceType,
                area: area
            })
        });

        const data = await response.json();

        loadingDiv.style.display = 'none';

        if (data.success) {
            // Show success message with instance details (using safe textContent)
            resultDiv.textContent = '';
            resultDiv.style.background = 'rgba(0, 100, 0, 0.5)';
            resultDiv.style.border = '1px solid #00ff00';
            resultDiv.style.color = '#00ff00';

            const successText = '✓ Instance Launched Successfully!\\n\\n' +
                'Name: ' + data.instance.name + '\\n' +
                'Instance ID: ' + data.instance.instance_id + '\\n' +
                'Type: ' + data.instance.type + '\\n' +
                'Private IP: ' + data.instance.private_ip + '\\n' +
                'Area: ' + data.instance.area;

            resultDiv.textContent = successText;
            resultDiv.style.whiteSpace = 'pre-line';
            resultDiv.style.display = 'block';

            // Show status and refresh instances list
            showStatus(data.message, 'success');
            refreshInstances();

            // Auto-close modal after 3 seconds
            setTimeout(() => {
                closeModal();
            }, 3000);
        } else {
            // Show error message
            resultDiv.textContent = '✗ Launch Failed\\n\\n' + data.message;
            resultDiv.style.background = 'rgba(100, 0, 0, 0.5)';
            resultDiv.style.border = '1px solid #ff0000';
            resultDiv.style.color = '#ff0000';
            resultDiv.style.whiteSpace = 'pre-line';
            resultDiv.style.display = 'block';
            launchButton.disabled = false;
            showStatus(data.message, 'error');
        }
    } catch (error) {
        loadingDiv.style.display = 'none';
        resultDiv.textContent = '✗ Error\\n\\n' + error.message;
        resultDiv.style.background = 'rgba(100, 0, 0, 0.5)';
        resultDiv.style.border = '1px solid #ff0000';
        resultDiv.style.color = '#ff0000';
        resultDiv.style.whiteSpace = 'pre-line';
        resultDiv.style.display = 'block';
        launchButton.disabled = false;
        showStatus('Error launching instance: ' + error.message, 'error');
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
