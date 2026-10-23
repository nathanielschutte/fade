# The same names as production's outputs, so scripts work with FADE_STACK=staging.

output "url" {
  value = "https://${local.domain}"
}

output "region" {
  value = var.region
}

output "app_name" {
  value = local.name
}

output "artifacts_bucket" {
  value = data.aws_s3_bucket.artifacts.id
}

# Where scripts/deploy.sh saves staging's builds: with the release candidates
# (releases/main/), never production's releases/fade-server.
output "release_prefix" {
  value = "releases/main"
}

output "instance_id" {
  value = aws_instance.app.id
}

output "ssh_host" {
  value = local.name
}

output "ssh_config" {
  value = join("\n", [
    "Host ${local.name}",
    "  HostName ${aws_instance.app.id}",
    "  User ec2-user",
    "  IdentityFile ${trimsuffix(var.ssh_public_key_path, ".pub")}",
    "  IdentitiesOnly yes",
    "  HostKeyAlias ${local.name}",
    "  StrictHostKeyChecking accept-new",
    "  ServerAliveInterval 30",
    "  ProxyCommand aws ssm start-session --region ${var.region} --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p",
    "",
  ])
}
