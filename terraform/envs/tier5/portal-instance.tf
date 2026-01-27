# Portal EC2 Instance - Minimal Configuration
# This creates the portal instance with minimal user_data
# The full application is deployed via the deploy-portal.sh script

resource "aws_instance" "portal" {
  ami                    = local.ubuntu_ami
  instance_type          = "t3.small"  # Upgraded from t3.micro for faster startup
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = "david-capsule-vibecode-2026-01-17"

  # 100GB root volume
  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Minimal user_data - just install dependencies and create user
  user_data = base64encode(<<-EOF
#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y python3-pip python3-venv git

# Create app directory and user
mkdir -p /opt/employee-portal
useradd -r -s /bin/bash app || true
chown -R app:app /opt/employee-portal

# Create virtual environment
cd /opt/employee-portal
python3 -m venv venv
source venv/bin/activate
pip install fastapi uvicorn[standard] python-jose[cryptography] boto3 jinja2 python-multipart

# Signal completion
touch /tmp/bootstrap-complete
EOF
  )

  tags = {
    Name = "${var.project_name}-portal"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# Update target group attachment to use new portal instance
resource "aws_lb_target_group_attachment" "portal" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.portal.id
  port             = 8000

  depends_on = [aws_instance.portal]
}

# Output portal instance details
output "portal_instance_id" {
  description = "Portal EC2 Instance ID"
  value       = aws_instance.portal.id
}

output "portal_private_ip" {
  description = "Portal EC2 Private IP"
  value       = aws_instance.portal.private_ip
}

output "portal_public_ip" {
  description = "Portal EC2 Public IP (if assigned)"
  value       = aws_instance.portal.public_ip
}
