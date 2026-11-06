variable "region" {
  type    = string
  default = "us-east-1"
}

variable "dns_zone" {
  description = "Route 53 zone; staging lives at staging.<zone>."
  type        = string
  default     = "napsack.io"
}

variable "instance_type" {
  description = "Load tests are more telling on the same size as production."
  type        = string
  default     = "t4g.micro"
}

variable "invite_code" {
  description = "Staging's own invite code (tests use it as NAPSACK_INVITE). Never production's."
  type        = string
  sensitive   = true
}

variable "admins" {
  description = "Staging Admins. The browser and smoke tests use e2e_admin and smoke_admin."
  type        = list(string)
  default     = ["e2e_admin", "smoke_admin"]
}

# Read by the scripts that test and reset staging (scripts/test-staging.sh,
# reset-staging.sh, test-ios.sh --staging), not by Terraform: declared so the
# tfvars file can hold them without a warning. Staging's own and never in the
# repository, so nobody else can sign in to its test accounts or its Admins.
variable "test_password" {
  description = "The password of staging's test accounts and seeded people (NAPSACK_PASSWORD)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "smoke_admin_key" {
  description = "Any long random string: smoke_admin's key on staging (NAPSACK_ADMIN_KEY)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "exempt_addresses" {
  description = "Public addresses of the machines running tests and load tests, exempt from per-address limits on staging."
  type        = list(string)
  default     = []
}

variable "ssh_public_keys" {
  description = "Same as production's: the machines allowed to SSH in (through SSM)."
  type        = list(string)
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "acme_email" {
  type    = string
  default = ""
}

variable "caddy_version" {
  type    = string
  default = "2.10.0"
}

# iPhone notifications (server/src/apns.rs; docs/operations/operations.md, iPhone notifications).
# All three empty (the default): iPhones get no notifications.
variable "apns_key" {
  description = "The APNs key's .p8 file, pasted whole (a heredoc). Staging's own: the Sandbox environment's key (Xcode builds), never production's."
  type        = string
  sensitive   = true
  default     = ""
}

variable "apns_key_id" {
  description = "The APNs key's Key ID (10 characters, from developer.apple.com)."
  type        = string
  default     = ""
}

variable "apple_team_id" {
  description = "The Apple Developer team's id (10 characters, Membership details)."
  type        = string
  default     = ""
}
