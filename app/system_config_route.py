# Add this route to /opt/employee-portal/app.py
# Insert before the final lines of the file

@app.get("/system-config", response_class=HTMLResponse)
async def system_config(request: Request):
    """System configuration and architecture diagram."""
    email, groups = require_auth(request)

    # Gather system information
    import socket
    import subprocess
    from datetime import datetime

    try:
        # Get current instance metadata using IMDSv2
        import requests

        # Get IMDSv2 token
        ec2_metadata_token = requests.put(
            "http://169.254.169.254/latest/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
            timeout=1
        ).text

        headers = {"X-aws-ec2-metadata-token": ec2_metadata_token}

        instance_id = requests.get(
            "http://169.254.169.254/latest/meta-data/instance-id",
            headers=headers, timeout=1
        ).text

        instance_type = requests.get(
            "http://169.254.169.254/latest/meta-data/instance-type",
            headers=headers, timeout=1
        ).text

        availability_zone = requests.get(
            "http://169.254.169.254/latest/meta-data/placement/availability-zone",
            headers=headers, timeout=1
        ).text

        local_ipv4 = requests.get(
            "http://169.254.169.254/latest/meta-data/local-ipv4",
            headers=headers, timeout=1
        ).text

        try:
            public_ipv4 = requests.get(
                "http://169.254.169.254/latest/meta-data/public-ipv4",
                headers=headers, timeout=1
            ).text
        except:
            public_ipv4 = "N/A (private subnet)"

    except Exception as e:
        print(f"Error fetching instance metadata: {e}")
        instance_id = "unknown"
        instance_type = "unknown"
        availability_zone = "unknown"
        local_ipv4 = "unknown"
        public_ipv4 = "unknown"

    hostname = socket.gethostname()

    system_info = {
        "instance_id": instance_id,
        "instance_type": instance_type,
        "availability_zone": availability_zone,
        "private_ip": local_ipv4,
        "public_ip": public_ipv4,
        "hostname": hostname,
        "current_time": datetime.utcnow().isoformat() + "Z",
        "user_pool_id": USER_POOL_ID,
        "aws_region": AWS_REGION,
    }

    return templates.TemplateResponse("system_config.html", {
        "request": request,
        "email": email,
        "groups": groups,
        "system_info": system_info
    })
