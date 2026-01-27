# SES Email Identity for sending MFA codes
resource "aws_ses_email_identity" "noreply" {
  email = "noreply@capsule-playground.com"
}

# Optional: Verify domain instead of individual email
# Uncomment if you have DNS access to capsule-playground.com
# resource "aws_ses_domain_identity" "capsule" {
#   domain = "capsule-playground.com"
# }
#
# resource "aws_route53_record" "ses_verification" {
#   zone_id = data.aws_route53_zone.main.zone_id
#   name    = "_amazonses.capsule-playground.com"
#   type    = "TXT"
#   ttl     = 600
#   records = [aws_ses_domain_identity.capsule.verification_token]
# }
