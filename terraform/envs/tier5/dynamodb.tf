# DynamoDB table for storing temporary MFA codes
resource "aws_dynamodb_table" "mfa_codes" {
  name         = "${var.project_name}-mfa-codes"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "username"

  attribute {
    name = "username"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name        = "${var.project_name}-mfa-codes"
    Environment = var.environment
  }
}
