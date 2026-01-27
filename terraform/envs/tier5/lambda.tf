# IAM Role for MFA Lambda functions
resource "aws_iam_role" "mfa_lambda_role" {
  name = "${var.project_name}-mfa-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-mfa-lambda-role"
  }
}

# IAM Policy for Lambda functions (SES, DynamoDB, CloudWatch)
resource "aws_iam_role_policy" "mfa_lambda_policy" {
  name = "${var.project_name}-mfa-lambda-policy"
  role = aws_iam_role.mfa_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.mfa_codes.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Data source to create Lambda ZIP files
data "archive_file" "define_auth_challenge" {
  type        = "zip"
  source_file = "${path.module}/lambdas/define_auth_challenge.py"
  output_path = "${path.module}/lambdas/define_auth_challenge.zip"
}

data "archive_file" "create_auth_challenge" {
  type        = "zip"
  source_file = "${path.module}/lambdas/create_auth_challenge.py"
  output_path = "${path.module}/lambdas/create_auth_challenge.zip"
}

data "archive_file" "verify_auth_challenge" {
  type        = "zip"
  source_file = "${path.module}/lambdas/verify_auth_challenge.py"
  output_path = "${path.module}/lambdas/verify_auth_challenge.zip"
}

# DefineAuthChallenge Lambda
resource "aws_lambda_function" "define_auth_challenge" {
  filename         = data.archive_file.define_auth_challenge.output_path
  function_name    = "${var.project_name}-define-auth-challenge"
  role             = aws_iam_role.mfa_lambda_role.arn
  handler          = "define_auth_challenge.lambda_handler"
  runtime          = "python3.11"
  timeout          = 10
  source_code_hash = data.archive_file.define_auth_challenge.output_base64sha256

  environment {
    variables = {
      MFA_CODES_TABLE = aws_dynamodb_table.mfa_codes.name
    }
  }

  tags = {
    Name = "${var.project_name}-define-auth-challenge"
  }
}

# CreateAuthChallenge Lambda
resource "aws_lambda_function" "create_auth_challenge" {
  filename         = data.archive_file.create_auth_challenge.output_path
  function_name    = "${var.project_name}-create-auth-challenge"
  role             = aws_iam_role.mfa_lambda_role.arn
  handler          = "create_auth_challenge.lambda_handler"
  runtime          = "python3.11"
  timeout          = 10
  source_code_hash = data.archive_file.create_auth_challenge.output_base64sha256

  environment {
    variables = {
      MFA_CODES_TABLE = aws_dynamodb_table.mfa_codes.name
      SES_FROM_EMAIL  = "noreply@capsule-playground.com"
    }
  }

  tags = {
    Name = "${var.project_name}-create-auth-challenge"
  }
}

# VerifyAuthChallenge Lambda
resource "aws_lambda_function" "verify_auth_challenge" {
  filename         = data.archive_file.verify_auth_challenge.output_path
  function_name    = "${var.project_name}-verify-auth-challenge"
  role             = aws_iam_role.mfa_lambda_role.arn
  handler          = "verify_auth_challenge.lambda_handler"
  runtime          = "python3.11"
  timeout          = 10
  source_code_hash = data.archive_file.verify_auth_challenge.output_base64sha256

  environment {
    variables = {
      MFA_CODES_TABLE = aws_dynamodb_table.mfa_codes.name
    }
  }

  tags = {
    Name = "${var.project_name}-verify-auth-challenge"
  }
}

# Lambda permissions for Cognito to invoke
resource "aws_lambda_permission" "allow_cognito_define" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.define_auth_challenge.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_lambda_permission" "allow_cognito_create" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_auth_challenge.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_lambda_permission" "allow_cognito_verify" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.verify_auth_challenge.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}
