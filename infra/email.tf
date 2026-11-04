# Email (server/src/reports.rs, docs/design/report-and-block.md): a note to the
# support address for each new report, linking to it on System › Reports. Sent
# through Amazon SES from noreply@<domain>, signed with DKIM.
#
# SES starts every account in its sandbox, which sends only to verified
# addresses. That's all this needs: the one recipient is verified here, and
# AWS emails it a link to click once after the first apply.

variable "reports_email" {
  description = "Where each new report is emailed (the support address). Empty: no email; reports are still on System › Reports."
  type        = string
  default     = ""
}

locals {
  # Needs the domain's zone here, for its DKIM records.
  send_email = var.reports_email != "" && var.dns_zone != ""
}

resource "aws_sesv2_email_identity" "domain" {
  count          = local.send_email ? 1 : 0
  email_identity = local.domain
}

# Easy DKIM: three CNAMEs that let SES sign as the domain.
resource "aws_route53_record" "ses_dkim" {
  count   = local.send_email ? 3 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# The recipient, verified while the account is in the sandbox.
resource "aws_sesv2_email_identity" "reports_to" {
  count          = local.send_email ? 1 : 0
  email_identity = var.reports_email
}

# The server may send from noreply@<domain> only, to the verified recipient
# (in the sandbox, SES checks both identities).
resource "aws_iam_role_policy" "email" {
  count = local.send_email ? 1 : 0
  name  = "${var.app_name}-email"
  role  = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EmailReports"
      Effect = "Allow"
      Action = ["ses:SendEmail"]
      Resource = [
        aws_sesv2_email_identity.domain[0].arn,
        aws_sesv2_email_identity.reports_to[0].arn,
      ]
      Condition = { StringEquals = { "ses:FromAddress" = "noreply@${local.domain}" } }
    }]
  })
}
