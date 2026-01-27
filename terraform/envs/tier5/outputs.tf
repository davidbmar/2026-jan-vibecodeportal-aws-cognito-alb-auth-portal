output "portal_url" {
  description = "Portal URL with custom domain"
  value       = "https://${aws_route53_record.portal.name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "route53_nameservers" {
  description = "Route53 nameservers - Update these in your domain registrar"
  value       = data.aws_route53_zone.main.name_servers
}

output "cognito_user_pool_id" {
  description = "ID of the Cognito User Pool"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_app_client_id" {
  description = "ID of the Cognito App Client"
  value       = aws_cognito_user_pool_client.main.id
}

output "cognito_app_client_secret" {
  description = "Secret of the Cognito App Client"
  value       = aws_cognito_user_pool_client.main.client_secret
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito User Pool Domain"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "example_urls" {
  description = "Example URLs to access the application"
  value = {
    home        = "https://${aws_route53_record.portal.name}/"
    directory   = "https://${aws_route53_record.portal.name}/directory"
    engineering = "https://${aws_route53_record.portal.name}/areas/engineering"
    hr          = "https://${aws_route53_record.portal.name}/areas/hr"
    automation  = "https://${aws_route53_record.portal.name}/areas/automation"
    product     = "https://${aws_route53_record.portal.name}/areas/product"
    health      = "https://${aws_route53_record.portal.name}/health"
  }
}

output "user_password_commands" {
  description = "Commands to set initial passwords for users"
  value       = <<-EOT
    # Set passwords for users (replace YOUR_PASSWORD with actual password):

    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.main.id} \
      --username dmar@capsule.com \
      --password YOUR_PASSWORD \
      --permanent \
      --region ${var.aws_region}

    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.main.id} \
      --username jahn@capsule.com \
      --password YOUR_PASSWORD \
      --permanent \
      --region ${var.aws_region}

    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.main.id} \
      --username ahatcher@capsule.com \
      --password YOUR_PASSWORD \
      --permanent \
      --region ${var.aws_region}

    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.main.id} \
      --username peter@capsule.com \
      --password YOUR_PASSWORD \
      --permanent \
      --region ${var.aws_region}

    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.main.id} \
      --username sdedakia@capsule.com \
      --password YOUR_PASSWORD \
      --permanent \
      --region ${var.aws_region}
  EOT
}
