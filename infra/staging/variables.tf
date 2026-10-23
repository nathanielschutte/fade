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
  default     = "t4g.nano"
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
