# SMS MFA Configuration for Cognito
# Add this to enable SMS as an MFA option alongside TOTP

# IAM Role for Cognito to send SMS via SNS
resource "aws_iam_role" "cognito_sms_role" {
  name = "${var.project_name}-cognito-sms-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cognito-idp.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "${var.project_name}-external"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-cognito-sms-role"
  }
}

# Policy for the role to publish SMS via SNS
resource "aws_iam_role_policy" "cognito_sms_policy" {
  name = "${var.project_name}-cognito-sms-policy"
  role = aws_iam_role.cognito_sms_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "*"
      }
    ]
  })
}

# Output the role ARN for reference
output "cognito_sms_role_arn" {
  description = "ARN of the IAM role used by Cognito for SMS MFA"
  value       = aws_iam_role.cognito_sms_role.arn
}

# Note: You'll need to update the aws_cognito_user_pool resource with:
#
# 1. Change mfa_configuration from "ON" to "OPTIONAL"
# 2. Add sms_configuration block
# 3. Add phone_number to schema
#
# See sms_mfa_instructions.md for the complete changes needed to main.tf
