# ─────────────────────────────────────────────────────────────
# Amazon SES — verify authengine.org + Easy DKIM (region ap-south-1)
# Lets AuthEngine send email OTP / verification from noreply@authengine.org
# ─────────────────────────────────────────────────────────────

variable "ses_domain" {
  description = "Domain to verify in SES for sending. Empty -> uses root_domain."
  type        = string
  default     = ""
}

variable "ses_from_local_part" {
  description = "Local part of the sender address (noreply -> noreply@<domain>)."
  type        = string
  default     = "noreply"
}

variable "ses_mail_from_subdomain" {
  description = "Subdomain for a custom MAIL FROM (e.g. 'mail' -> mail.<domain>). Empty to skip."
  type        = string
  default     = "mail"
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID to auto-create SES DNS records. Empty -> manage DNS manually (e.g. Cloudflare) using the ses_dns_records output."
  type        = string
  default     = ""
}

variable "request_ses_production_access" {
  description = "If true, requests moving the SES account out of the sandbox via the SES API (needs AWS CLI + creds on the Terraform runner)."
  type        = bool
  default     = false
}

variable "ses_use_case_description" {
  description = "Justification sent to AWS when requesting SES production access."
  type        = string
  default     = "AuthEngine sends transactional authentication emails (email verification links and one-time passcodes) only to users who explicitly sign up. No marketing email is sent."
}

locals {
  ses_domain       = var.ses_domain != "" ? var.ses_domain : var.root_domain
  ses_from_address = "${var.ses_from_local_part}@${local.ses_domain}"
  ses_manage_dns   = var.route53_zone_id != ""
  ses_has_mailfrom = var.ses_mail_from_subdomain != ""
}

resource "aws_ses_domain_identity" "main" {
  domain = local.ses_domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_domain_mail_from" "main" {
  count                  = local.ses_has_mailfrom ? 1 : 0
  domain                 = aws_ses_domain_identity.main.domain
  mail_from_domain       = "${var.ses_mail_from_subdomain}.${aws_ses_domain_identity.main.domain}"
  behavior_on_mx_failure = "UseDefaultValue"
}

# ── Optional: create the DNS records automatically when using Route53 ──
resource "aws_route53_record" "ses_verification" {
  count   = local.ses_manage_dns ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "_amazonses.${local.ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.main.verification_token]
}

resource "aws_route53_record" "ses_dkim" {
  count   = local.ses_manage_dns ? 3 : 0
  zone_id = var.route53_zone_id
  name    = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}._domainkey.${local.ses_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.main.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_mx" {
  count   = (local.ses_manage_dns && local.ses_has_mailfrom) ? 1 : 0
  zone_id = var.route53_zone_id
  name    = aws_ses_domain_mail_from.main[0].mail_from_domain
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${var.aws_region}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  count   = (local.ses_manage_dns && local.ses_has_mailfrom) ? 1 : 0
  zone_id = var.route53_zone_id
  name    = aws_ses_domain_mail_from.main[0].mail_from_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com ~all"]
}

# ── Let the API's EC2 role send via SES (key-less, least privilege) ──
resource "aws_iam_role_policy" "ec2_ses_send" {
  name = "${var.project_name}-ses-send"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      Condition = {
        StringEquals = { "ses:FromAddress" = local.ses_from_address }
      }
    }]
  })
}

# ── Optional: request production access (exit the SES sandbox) ──
# No native Terraform resource exists for this; it maps to the SES account API.
resource "null_resource" "ses_production_access" {
  count = var.request_ses_production_access ? 1 : 0

  triggers = {
    domain = local.ses_domain
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws sesv2 put-account-details \
        --region ${var.aws_region} \
        --production-access-enabled \
        --mail-type TRANSACTIONAL \
        --website-url "https://${var.root_domain}" \
        --contact-language EN \
        --use-case-description "${var.ses_use_case_description}"
    EOT
  }
}

# ── Outputs: DNS records to add manually (e.g. in Cloudflare) ──
output "ses_dns_records" {
  description = "Add these to DNS to verify the SES domain + enable DKIM. Ignore if route53_zone_id was set (records are created automatically)."
  value = {
    domain_verification_txt = {
      name  = "_amazonses.${local.ses_domain}"
      type  = "TXT"
      value = aws_ses_domain_identity.main.verification_token
    }
    dkim_cnames = [
      for t in aws_ses_domain_dkim.main.dkim_tokens : {
        name  = "${t}._domainkey.${local.ses_domain}"
        type  = "CNAME"
        value = "${t}.dkim.amazonses.com"
      }
    ]
    mail_from_mx = local.ses_has_mailfrom ? {
      name  = "${var.ses_mail_from_subdomain}.${local.ses_domain}"
      type  = "MX"
      value = "10 feedback-smtp.${var.aws_region}.amazonses.com"
    } : null
    mail_from_spf = local.ses_has_mailfrom ? {
      name  = "${var.ses_mail_from_subdomain}.${local.ses_domain}"
      type  = "TXT"
      value = "v=spf1 include:amazonses.com ~all"
    } : null
  }
}

output "ses_from_address" {
  description = "Sender address AuthEngine is authorized to send from (set as EMAIL_SENDER)."
  value       = local.ses_from_address
}

output "ses_production_access_cli" {
  description = "Run this to request SES production access if request_ses_production_access was left false."
  value       = "aws sesv2 put-account-details --region ${var.aws_region} --production-access-enabled --mail-type TRANSACTIONAL --website-url https://${var.root_domain} --contact-language EN --use-case-description \"transactional auth OTP/verification emails\""
}
