# Database backups: an hourly consistent copy of the SQLite database, kept 30
# days (docs/operations/backups.md): a deleted account is gone from every copy
# within 30 days (Nate, 2026-11-03; docs/design/account-deletion.md). The instance
# can only add objects here, never delete or overwrite them, and versioning keeps
# anything that does change until the lifecycle below removes it.

resource "aws_s3_bucket" "backups" {
  bucket = "${var.app_name}-backups-${data.aws_caller_identity.current.account_id}-${var.region}"

  lifecycle {
    # Holds the only off-machine copies of everyone's data.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Database backups last 30 days, then go, every version of them. Deletion
# markers (`deletions/<id>`, ids only) are kept: a restored backup is wiped
# again from them at start (server/src/deletion.rs).
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "backups-last-30-days"
    status = "Enabled"
    filter { prefix = "db/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
  rule {
    id     = "expired-backup-markers"
    status = "Enabled"
    filter { prefix = "db/" }
    expiration { expired_object_delete_marker = true }
  }
}
