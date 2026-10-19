output "url" {
  value = "https://${local.domain}"
}

output "instance_id" {
  value = aws_instance.app.id
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}

output "region" {
  value = var.region
}

output "ssh_host" {
  value = var.app_name
}

output "ssh_config" {
  description = "ssh_config block used by scripts/ssh.sh and deploy.sh. Append it to ~/.ssh/config to use plain `ssh fade`."
  value = join("\n", concat(
    [
      "Host ${var.app_name}",
      "  HostName ${length(var.ssh_allowed_cidrs) > 0 ? aws_eip.app.public_ip : aws_instance.app.id}",
      "  User ec2-user",
      "  IdentityFile ${trimsuffix(var.ssh_public_key_path, ".pub")}",
      "  IdentitiesOnly yes",
      # Host keys persist on the data volume, so this stays valid across instance replacement.
      "  HostKeyAlias ${var.app_name}",
      "  StrictHostKeyChecking accept-new",
      "  ServerAliveInterval 30",
    ],
    length(var.ssh_allowed_cidrs) > 0 ? [] : [
      "  ProxyCommand aws ssm start-session --region ${var.region} --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p",
    ],
    [""],
  ))
}

output "shell" {
  description = "Open a shell on the box (needs the Session Manager plugin)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.app.id}"
}
