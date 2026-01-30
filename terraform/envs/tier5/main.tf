terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Hardcoded values to avoid needing DescribeAvailabilityZones and DescribeImages permissions
locals {
  availability_zones = ["us-west-2a", "us-west-2b"]
  # Ubuntu 22.04 LTS AMI for us-west-2 (update periodically)
  ubuntu_ami  = "ami-0aff18ec83b712f05"
  domain_name = "capsule-playground.com"
  subdomain   = "portal.${local.domain_name}"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route53 Hosted Zone (use existing registrar zone)
data "aws_route53_zone" "main" {
  zone_id = "Z08060212RCF52XOT632U"
}

# ACM Certificate
resource "aws_acm_certificate" "main" {
  domain_name       = local.subdomain
  validation_method = "DNS"

  tags = {
    Name = "${var.project_name}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Route53 Record for ACM DNS Validation
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# ACM Certificate Validation
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from anywhere"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS from anywhere"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow traffic from ALB only"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["44.244.76.51/32"]
    description = "SSH access for debugging"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

# Cognito User Pool
resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  mfa_configuration = "OFF"

  # Lambda triggers for email MFA
  lambda_config {
    define_auth_challenge          = aws_lambda_function.define_auth_challenge.arn
    create_auth_challenge          = aws_lambda_function.create_auth_challenge.arn
    verify_auth_challenge_response = aws_lambda_function.verify_auth_challenge.arn
  }

  # SMS MFA Configuration - Commented out due to iam:PassRole permissions
  # sms_configuration {
  #   external_id    = "${var.project_name}-external"
  #   sns_caller_arn = aws_iam_role.cognito_sms_role.arn
  # }

  # sms_authentication_message = "Your Employee Portal authentication code is {####}"

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # Phone number schema for SMS MFA
  schema {
    name                = "phone_number"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }

  tags = {
    Name = "${var.project_name}-user-pool"
  }
}

# Cognito User Pool Domain
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-${random_string.domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "random_string" "domain_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Cognito User Pool Client
resource "aws_cognito_user_pool_client" "main" {
  name         = "${var.project_name}-app-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # Authentication flows including custom auth for email MFA
  explicit_auth_flows = [
    "ALLOW_CUSTOM_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = [
    "https://${local.subdomain}/oauth2/idpresponse"
  ]

  logout_urls = [
    "https://${local.subdomain}",
    "https://${local.subdomain}/logged-out"
  ]

  supported_identity_providers = ["COGNITO"]
  generate_secret              = true
}

# Cognito Groups
resource "aws_cognito_user_group" "engineering" {
  name         = "engineering"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Engineering team members"
}

resource "aws_cognito_user_group" "hr" {
  name         = "hr"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "HR team members"
}

resource "aws_cognito_user_group" "automation" {
  name         = "automation"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Automation team members"
}

resource "aws_cognito_user_group" "product" {
  name         = "product"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Product team members"
}

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Admin users"
}

# Cognito Users
resource "aws_cognito_user" "dmar" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "dmar@capsule.com"

  attributes = {
    email          = "dmar@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "dmar_engineering" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.engineering.name
  username     = aws_cognito_user.dmar.username
}

resource "aws_cognito_user_in_group" "dmar_admins" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.admins.name
  username     = aws_cognito_user.dmar.username
}

resource "aws_cognito_user" "jahn" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "jahn@capsule.com"

  attributes = {
    email          = "jahn@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "jahn_engineering" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.engineering.name
  username     = aws_cognito_user.jahn.username
}

resource "aws_cognito_user_in_group" "jahn_admins" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.admins.name
  username     = aws_cognito_user.jahn.username
}

resource "aws_cognito_user" "ahatcher" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "ahatcher@capsule.com"

  attributes = {
    email          = "ahatcher@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "ahatcher_hr" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.hr.name
  username     = aws_cognito_user.ahatcher.username
}

resource "aws_cognito_user" "peter" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "peter@capsule.com"

  attributes = {
    email          = "peter@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "peter_automation" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.automation.name
  username     = aws_cognito_user.peter.username
}

resource "aws_cognito_user" "sdedakia" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "sdedakia@capsule.com"

  attributes = {
    email          = "sdedakia@capsule.com"
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "sdedakia_product" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.product.name
  username     = aws_cognito_user.sdedakia.username
}

# Set permanent passwords for all users
resource "null_resource" "set_user_passwords" {
  depends_on = [
    aws_cognito_user.dmar,
    aws_cognito_user.jahn,
    aws_cognito_user.ahatcher,
    aws_cognito_user.peter,
    aws_cognito_user.sdedakia
  ]

  triggers = {
    user_pool_id = aws_cognito_user_pool.main.id
    password     = "SecurePass123!"
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws cognito-idp admin-set-user-password \
        --user-pool-id ${aws_cognito_user_pool.main.id} \
        --username dmar@capsule.com \
        --password 'SecurePass123!' \
        --permanent \
        --region ${var.aws_region}

      aws cognito-idp admin-set-user-password \
        --user-pool-id ${aws_cognito_user_pool.main.id} \
        --username jahn@capsule.com \
        --password 'SecurePass123!' \
        --permanent \
        --region ${var.aws_region}

      aws cognito-idp admin-set-user-password \
        --user-pool-id ${aws_cognito_user_pool.main.id} \
        --username ahatcher@capsule.com \
        --password 'SecurePass123!' \
        --permanent \
        --region ${var.aws_region}

      aws cognito-idp admin-set-user-password \
        --user-pool-id ${aws_cognito_user_pool.main.id} \
        --username peter@capsule.com \
        --password 'SecurePass123!' \
        --permanent \
        --region ${var.aws_region}

      aws cognito-idp admin-set-user-password \
        --user-pool-id ${aws_cognito_user_pool.main.id} \
        --username sdedakia@capsule.com \
        --password 'SecurePass123!' \
        --permanent \
        --region ${var.aws_region}
    EOT
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}

resource "aws_iam_role_policy" "ec2_cognito" {
  name = "${var.project_name}-ec2-cognito-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminListGroupsForUser",
          "cognito-idp:AdminGetUser",
          "cognito-idp:AdminSetUserMFAPreference",
          "cognito-idp:ListUsers",
          "cognito-idp:ListGroups",
          "cognito-idp:AdminAddUserToGroup",
          "cognito-idp:AdminRemoveUserFromGroup",
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminDeleteUser",
          "cognito-idp:AdminSetUserPassword",
          "cognito-idp:AdminListUserAuthEvents",
          "cognito-idp:GetGroup",
          "cognito-idp:CreateGroup"
        ]
        Resource = aws_cognito_user_pool.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:CreateTags",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:CreateSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ALB
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# Route53 A Record pointing to ALB
resource "aws_route53_record" "portal" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.subdomain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_target_group" "main" {
  name     = "${var.project_name}-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

# HTTP Listener - Redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener - Forward to app (auth handled by app)
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/health"]
    }
  }
}

resource "aws_lb_listener_rule" "logged_out" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/logged-out"]
    }
  }
}

resource "aws_lb_listener_rule" "password_reset" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 3

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/password-reset"]
    }
  }
}

resource "aws_lb_listener_rule" "password_reset_success" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 4

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/password-reset-success"]
    }
  }
}

resource "aws_lb_listener_rule" "password_reset_api" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/api/password-reset/*"]
    }
  }
}

resource "aws_lb_listener_rule" "logout_and_reset" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 6

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/logout-and-reset"]
    }
  }
}

resource "aws_lb_listener_rule" "authenticated" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

# EC2 Instance - COMMENTED OUT - Using portal-instance.tf instead
# The old user_data.sh approach exceeded AWS 16KB limit
# resource "aws_instance" "app" {
#   ami                    = local.ubuntu_ami
#   instance_type          = "t3.micro"
#   subnet_id              = aws_subnet.public[0].id
#   vpc_security_group_ids = [aws_security_group.ec2.id]
#   iam_instance_profile   = aws_iam_instance_profile.ec2.name
#
#   user_data = base64gzip(templatefile("${path.module}/user_data.sh", {
#     user_pool_id = aws_cognito_user_pool.main.id
#     aws_region   = var.aws_region
#   }))
#
#   tags = {
#     Name = "${var.project_name}-app"
#   }
# }
#
# resource "aws_lb_target_group_attachment" "app" {
#   target_group_arn = aws_lb_target_group.main.arn
#   target_id        = aws_instance.app.id
#   port             = 8000
# }

# Temporary SSH access for debugging
