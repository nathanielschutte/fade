variable "app_name" {
  description = "Internal name, used for resource names and tags. Rename later without touching code."
  type        = string
  default     = "fade"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "ssh_public_keys" {
  description = "Public keys (the key text, not file paths) allowed to SSH as ec2-user. List one per machine you work from, e.g. Windows and WSL, so it doesn't matter where terraform runs. Empty falls back to ssh_public_key_path."
  type        = list(string)
  default     = []
}

variable "ssh_public_key_path" {
  description = "Public key installed for ec2-user. The matching private key (same path minus .pub) is used by scripts/ssh.sh and deploy.sh."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_cidrs" {
  description = "Source ranges allowed to reach port 22 directly, e.g. [\"203.0.113.7/32\"]. Leave empty to keep port 22 closed and tunnel SSH through SSM instead."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "Graviton is the cheapest per vCPU. t4g.nano (512 MB) is plenty for a handful of friends."
  type        = string
  default     = "t4g.nano"
}

variable "domain" {
  description = "Hostname to serve on. Leave empty to use <elastic-ip>.sslip.io, which works with Let's Encrypt and needs no DNS setup."
  type        = string
  default     = ""
}

variable "redirect_domains" {
  description = "Old hostnames that should permanently redirect to `domain`. Their DNS must still point at the elastic IP so Caddy can get certificates for them."
  type        = list(string)
  default     = []
}

variable "acme_email" {
  description = "Email for Let's Encrypt expiry notices (optional)."
  type        = string
  default     = ""
}

variable "invite_code" {
  description = "Required to create an account. Stored in SSM Parameter Store as a SecureString."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{8,64}$", var.invite_code))
    error_message = "Use 8-64 characters: letters, numbers, dot, underscore, dash."
  }
}

variable "github_repo" {
  description = "owner/name of the GitHub repo allowed to deploy releases (infra/github.tf). Empty disables CI deploys."
  type        = string
  default     = "nathanielschutte/fade"
}

variable "admin_usernames" {
  description = "Usernames that can open /admin (stats only, never message content). Register these accounts before sharing the invite code."
  type        = list(string)
  default     = ["nate", "chris", "nateschutte", "gayboy1"]
}

variable "snap_disk_mb" {
  description = "Max disk for all unopened direct pics combined (they wait on the data volume until opened or expired)."
  type        = number
  default     = 256
}

variable "snap_ttl_hours" {
  description = "Unopened pics expire after this long."
  type        = number
  default     = 720
}

variable "data_volume_gb" {
  description = "Separate EBS volume for the SQLite DB and TLS certs. Survives instance replacement."
  type        = number
  default     = 1
}

variable "snapshot_retain_days" {
  description = "Daily snapshots of the data volume kept for this many days. 0 disables them. Hourly database backups to S3 (backups.tf) are separate and kept forever."
  type        = number
  default     = 30
}

variable "caddy_version" {
  description = "Caddy release to install from GitHub."
  type        = string
  default     = "2.10.0"
}
