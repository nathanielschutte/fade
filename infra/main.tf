terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # For a team or CI, move state to S3:
  # backend "s3" { bucket = "...", key = "fade/terraform.tfstate", region = "us-east-1", use_lockfile = true }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { App = var.app_name, ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

# Latest Amazon Linux 2023 for ARM. Pinned after first apply (see lifecycle below).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  ssh_keys = length(var.ssh_public_keys) > 0 ? var.ssh_public_keys : [trimspace(file(pathexpand(var.ssh_public_key_path)))]
  az       = data.aws_availability_zones.available.names[0]
  domain   = var.domain != "" ? var.domain : "${replace(aws_eip.app.public_ip, ".", "-")}.sslip.io"
  env_file = join("\n", [
    "FADE_INVITE_CODE=${var.invite_code}",
    # Admins live in their own parameter, outside Terraform (docs/roles.md; scripts/set-admins.sh).
    "FADE_ADMINS_PARAM=/${var.app_name}/admins",
    "FADE_SNAP_DISK_MB=${var.snap_disk_mb}",
    "FADE_SNAP_TTL_HOURS=${var.snap_ttl_hours}",
    # The contact in push notification requests (VAPID); never hardcoded in the server.
    "FADE_PUBLIC_URL=https://${local.domain}",
    "",
  ])
}

# ---------- network ----------
# A tiny public VPC. No NAT gateway: that alone would cost ~$32/month.

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.app_name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.app_name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true # outbound works during bootstrap, before the EIP attaches
  tags                    = { Name = "${var.app_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.app_name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# HTTP/HTTPS, plus SSH only from var.ssh_allowed_cidrs. With none set, SSH
# still works, tunneled through SSM Session Manager with no open port.
resource "aws_security_group" "app" {
  name        = "${var.app_name}-web"
  description = "HTTPS for ${var.app_name}"
  vpc_id      = aws_vpc.main.id

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
  dynamic "ingress" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
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
  tags   = { Name = var.app_name }
}

# ---------- artifacts + config ----------

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.app_name}-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# Whole env file as one SecureString. The service re-reads it on every start,
# so changing config is `terraform apply` + `systemctl restart fade`.
resource "aws_ssm_parameter" "env" {
  name  = "/${var.app_name}/env"
  type  = "SecureString"
  value = local.env_file
}

# ---------- IAM ----------

resource "aws_iam_role" "instance" {
  name = "${var.app_name}-instance"
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
  name = "${var.app_name}-runtime"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadReleases"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/releases/*"
      },
      {
        Sid      = "ListReleases"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
      },
      {
        # Decryption uses the AWS-managed aws/ssm key, whose key policy already allows this account.
        Sid    = "ReadConfig"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        # The settings, and the admin list (set outside Terraform; docs/roles.md).
        Resource = [
          aws_ssm_parameter.env.arn,
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.app_name}/admins",
        ]
      },
      {
        # Add backups only: no delete, no read, no listing. Keys are unique per
        # run, and versioning keeps any object that does get overwritten.
        Sid      = "WriteBackups"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backups.arn}/db/*"
      },
      {
        # The Metrics tab's incidents (server/src/incidents.rs, Admins only):
        # read the health monitor's records, and add a resolution beside one.
        # Never the monitor's state, never a delete.
        Sid    = "ReadIncidents"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.artifacts.arn}/health/incidents/*",
          "${aws_s3_bucket.artifacts.arn}/health/resolutions/*",
        ]
      },
      {
        Sid      = "MarkIncidentsResolved"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/health/resolutions/*"
      },
      {
        # The admin Metrics tab (server/src/metrics.rs): this instance's CPU
        # credits, every 5 minutes. Read-only, and inside the free tier.
        # GetMetricStatistics has no resource-level permissions, hence "*".
        Sid      = "ReadCpuCredits"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        # The admin Metrics tab's billed cost, twice a day ($0.01 a call).
        # Read-only; Cost Explorer has no resource-level permissions.
        Sid      = "ReadCosts"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.app_name}-instance"
  role = aws_iam_role.instance.name
}

# ---------- storage ----------
# DB and TLS certs live here, not on the root disk, so the instance can be
# replaced (new AMI, new user_data) without losing accounts or chats.

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  # If the volume is ever deleted anyway, snapshot it first.
  final_snapshot = true
  tags = {
    Name   = "${var.app_name}-data"
    Backup = "${var.app_name}-daily"
  }

  lifecycle {
    # Holds every account and chat. To really delete it, remove this first.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
  # Stop cleanly so the filesystem is unmounted before detach (on replacement).
  stop_instance_before_detaching = true
}

# ---------- instance ----------

# EC2 installs one key; the boot script adds the rest of ssh_public_keys.
resource "aws_key_pair" "admin" {
  key_name   = "${var.app_name}-admin"
  public_key = local.ssh_keys[0]
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = aws_key_pair.admin.key_name

  # Unlimited mode can bill for CPU credits; standard just throttles.
  credit_specification { cpu_credits = "standard" }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    app_name      = var.app_name
    region        = var.region
    bucket        = aws_s3_bucket.artifacts.id
    env_param     = aws_ssm_parameter.env.name
    domain        = local.domain
    redirects     = var.redirect_domains
    ssh_keys      = local.ssh_keys
    acme_email    = var.acme_email
    volume_serial = replace(aws_ebs_volume.data.id, "-", "")
    caddy_version = var.caddy_version
    backup_bucket = aws_s3_bucket.backups.id
  })
  user_data_replace_on_change = true

  tags = { Name = var.app_name }

  lifecycle {
    # Don't replace the box every time AWS publishes a new AMI.
    # Taint or `-replace` it when you want to roll the OS.
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "app" {
  allocation_id = aws_eip.app.id
  instance_id   = aws_instance.app.id
}

# ---------- backups ----------

resource "aws_iam_role" "dlm" {
  count = var.snapshot_retain_days > 0 ? 1 : 0
  name  = "${var.app_name}-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count      = var.snapshot_retain_days > 0 ? 1 : 0
  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "daily" {
  count              = var.snapshot_retain_days > 0 ? 1 : 0
  description        = "Daily snapshots of ${var.app_name} data volume"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = "${var.app_name}-daily" }

    schedule {
      name = "daily"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["09:00"] # UTC, ~3-4am Chicago
      }
      retain_rule { count = var.snapshot_retain_days }
      copy_tags = true
    }
  }
}
