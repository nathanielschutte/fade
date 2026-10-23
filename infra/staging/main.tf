# Staging (docs/operations/staging.md): a second, separate napsack on staging.<domain>,
# for browser tests against a real deployment and for load tests.
#
# Isolation from production:
# - Its own Terraform state (this folder). Nothing here can change a
#   production resource; production's network is only looked up.
# - Its own server, Elastic IP, security group, data volume, settings, and
#   instance role, tagged App=fade-staging. Production's health monitor
#   watches App=fade only, and the cost tag stays production's.
# - Its role can read only staging's settings and staging's releases
#   (releases/staging/); it can't read production's settings or data, or
#   write to the backups bucket.
# - No backups: the backup timer isn't enabled, and it couldn't write anyway.
#
# The boot script is production's (../user_data.sh.tftpl), rendered here with
# two exact substitutions (backups off; staging's release file), each checked
# so a change to the template fails loudly rather than silently.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { App = "fade-staging", ManagedBy = "terraform", Stack = "staging" }
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------- production's network, looked up (never managed here) ----------

data "aws_vpc" "main" {
  tags = { Name = "fade" }
}

data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "fade-public" }
}

data "aws_s3_bucket" "artifacts" {
  bucket = "fade-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
}

data "aws_route53_zone" "zone" {
  name = var.dns_zone
}

locals {
  name   = "fade-staging"
  domain = "staging.${var.dns_zone}"
  env_file = join("\n", [
    "FADE_INVITE_CODE=${var.invite_code}",
    "FADE_ADMINS=${join(",", var.admins)}",
    "FADE_PUBLIC_URL=https://${local.domain}",
    # Room to load test: well past production's safety caps. (Sessions per
    # person stay at production's 4, which the smoke test checks.)
    "FADE_MAX_ACCOUNTS=100000",
    "FADE_REQUESTS_PER_ADDRESS=1000000",
    "FADE_MAX_SOCKETS=20000",
    "FADE_MAX_IN_FLIGHT=2000",
    # The test and load-test machines aren't rate limited per address (staging only).
    "FADE_EXEMPT_ADDRESSES=${join(",", var.exempt_addresses)}",
    # Staging's own incident records (never production's health/), for trying the Metrics tab's incidents.
    "FADE_HEALTH_PREFIX=staging/health/",
    "",
  ])
  release_key = "releases/staging/fade-server"
  rendered = templatefile("${path.module}/../user_data.sh.tftpl", {
    app_name      = "fade" # the machine's own names (user, paths, units), as in production
    region        = var.region
    bucket        = data.aws_s3_bucket.artifacts.id
    env_param     = aws_ssm_parameter.env.name
    domain        = local.domain
    redirects     = []
    ssh_keys      = var.ssh_public_keys
    acme_email    = var.acme_email
    volume_serial = replace(aws_ebs_volume.data.id, "-", "")
    caddy_version = var.caddy_version
    backup_bucket = ""
  })
  backup_timer = "systemctl enable --now $APP-backup.timer"
  release_path = "/releases/fade-server\""
  user_data = replace(
    replace(local.rendered, local.backup_timer, "echo 'staging: database backups are off'"),
    local.release_path, "/${local.release_key}\"",
  )
}

# ---------- settings ----------

resource "aws_ssm_parameter" "env" {
  name  = "/${local.name}/env"
  type  = "SecureString"
  value = local.env_file
}

# ---------- network pieces of its own ----------

resource "aws_security_group" "app" {
  name        = "${local.name}-web"
  description = "HTTPS for ${local.name}"
  vpc_id      = data.aws_vpc.main.id
  ingress {
    description = "HTTP (ACME challenge and redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP/3"
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "app" {
  domain = "vpc"
  tags   = { Name = local.name }
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = local.domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]
}

# ---------- the server ----------

resource "aws_iam_role" "instance" {
  name = "${local.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "instance" {
  name = "${local.name}-runtime"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStagingReleases"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.artifacts.arn}/releases/staging/*"
      },
      {
        Sid       = "ListStagingReleases"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = data.aws_s3_bucket.artifacts.arn
        Condition = { StringLike = { "s3:prefix" = ["releases/staging/*", "staging/health/*"] } }
      },
      {
        # Staging's own incident records (FADE_HEALTH_PREFIX), never production's health/.
        Sid      = "StagingIncidents"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.artifacts.arn}/staging/health/*"
      },
      {
        Sid      = "MarkStagingIncidentsResolved"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${data.aws_s3_bucket.artifacts.arn}/staging/health/resolutions/*"
      },
      {
        Sid      = "ReadStagingConfig"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.env.arn
      },
      {
        # AmazonSSMManagedInstanceCore (needed for SSM) allows reading every
        # parameter in the account. An explicit Deny overrides it: staging
        # must never read production's settings or admin list.
        Sid    = "NeverProductionSettings"
        Effect = "Deny"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/fade",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/fade/*",
        ]
      },
      {
        Sid      = "NoParameterListing"
        Effect   = "Deny"
        Action   = ["ssm:GetParametersByPath"]
        Resource = "*"
      },
      {
        # The Metrics tab's CPU credits. No Cost Explorer: staging's bill is production's account's.
        Sid      = "ReadCpuCredits"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.public.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-data" }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  credit_specification { cpu_credits = "standard" }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data                   = local.user_data
  user_data_replace_on_change = true
  tags                        = { Name = local.name }

  lifecycle {
    precondition {
      condition     = strcontains(local.rendered, local.backup_timer)
      error_message = "The boot script no longer contains '${local.backup_timer}': update staging's backup substitution."
    }
    precondition {
      condition     = length(regexall(local.release_path, local.rendered)) == 2 && !strcontains(local.user_data, local.release_path)
      error_message = "The boot script's release path changed: update staging's release substitution."
    }
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.app.id
  stop_instance_before_detaching = true
}

resource "aws_eip_association" "app" {
  allocation_id = aws_eip.app.id
  instance_id   = aws_instance.app.id
}
