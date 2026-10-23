# Lets GitHub Actions ship the server (docs/operations/releasing.md) with
# short-lived credentials. No AWS keys are stored in GitHub. Two roles, one
# per GitHub environment, so each job can reach only its own servers:
#
# - fade-github-staging (environment "staging", CI on every push to main):
#   uploads release candidates to releases/main/, keeps the newest ten, and
#   updates the staging server. It can't touch production's releases or
#   servers.
# - fade-github-deploy (environment "production", a server-v* tag): promotes
#   a candidate to releases/tags/ and releases/fade-server, takes a backup,
#   and updates production's servers.

locals {
  github_enabled = var.github_repo != ""
  artifacts      = aws_s3_bucket.artifacts.arn
  instances_arn  = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
  # What every deploy needs besides its own servers and releases.
  github_common_statements = [
    {
      # Only the stock run-a-script document.
      Sid      = "RunScriptDocument"
      Effect   = "Allow"
      Action   = ["ssm:SendCommand"]
      Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
    },
    {
      # Finding the instances and reading a command's result have no resource-level scoping.
      Sid      = "FindInstancesAndReadResults"
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
      Resource = "*"
    },
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.github_enabled ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Who may assume a role: jobs in this repo running in one GitHub environment.
data "aws_iam_policy_document" "github_trust" {
  for_each = local.github_enabled ? toset(["production", "staging"]) : toset([])
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${each.key}"]
    }
  }
}

# ---------- production: server-v* tags ----------

resource "aws_iam_role" "github_deploy" {
  count              = local.github_enabled ? 1 : 0
  name               = "${var.app_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust["production"].json
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.github_enabled ? 1 : 0
  name  = "${var.app_name}-release"
  role  = aws_iam_role.github_deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # The candidate that staging ran, to promote; and the release keys (to check one isn't taken).
        Sid      = "ReadReleases"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.artifacts}/releases/main/*", "${local.artifacts}/releases/tags/*"]
      },
      {
        Sid       = "ListReleases"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = local.artifacts
        Condition = { StringLike = { "s3:prefix" = ["releases/main/*", "releases/tags/*"] } }
      },
      {
        # A release, and making it what production runs. No deletes.
        Sid      = "PublishRelease"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${local.artifacts}/releases/tags/*", "${local.artifacts}/releases/fade-server"]
      },
      {
        # Only instances tagged as production's app, so it keeps working across instance replacement.
        Sid       = "RunOnProduction"
        Effect    = "Allow"
        Action    = ["ssm:SendCommand"]
        Resource  = local.instances_arn
        Condition = { StringEquals = { "ssm:resourceTag/App" = var.app_name } }
      },
    ], local.github_common_statements)
  })
}

# ---------- staging: every push to main ----------

resource "aws_iam_role" "github_staging" {
  count              = local.github_enabled ? 1 : 0
  name               = "${var.app_name}-github-staging"
  assume_role_policy = data.aws_iam_policy_document.github_trust["staging"].json
}

resource "aws_iam_role_policy" "github_staging" {
  count = local.github_enabled ? 1 : 0
  name  = "${var.app_name}-candidates"
  role  = aws_iam_role.github_staging[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # Release candidates only: upload, and delete all but the newest ten.
        Sid      = "Candidates"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${local.artifacts}/releases/main/*"
      },
      {
        Sid       = "ListCandidates"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = local.artifacts
        Condition = { StringLike = { "s3:prefix" = ["releases/main/*"] } }
      },
      {
        Sid       = "RunOnStaging"
        Effect    = "Allow"
        Action    = ["ssm:SendCommand"]
        Resource  = local.instances_arn
        Condition = { StringEquals = { "ssm:resourceTag/App" = "${var.app_name}-staging" } }
      },
    ], local.github_common_statements)
  })
}
