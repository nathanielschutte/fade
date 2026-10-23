# DNS for the app's address (docs/operations/domain-move.md), when its Route 53 zone is
# in this account: the domain itself and www point at the Elastic IP. (Old
# addresses that redirect keep their own records, made by hand.)

variable "dns_zone" {
  description = "The Route 53 zone holding `domain` (e.g. napsack.io). Empty: DNS is managed elsewhere."
  type        = string
  default     = ""
}

data "aws_route53_zone" "app" {
  count = var.dns_zone != "" ? 1 : 0
  name  = var.dns_zone
}

resource "aws_route53_record" "app" {
  count   = var.dns_zone != "" ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.dns_zone
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]
}

resource "aws_route53_record" "www" {
  count   = var.dns_zone != "" ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = "www.${var.dns_zone}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]
}
