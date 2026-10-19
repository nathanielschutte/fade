# Lets GitHub Actions deploy server releases (.github/workflows/release-server.yml)
# with short-lived credentials. No AWS keys are stored in GitHub.
# Only jobs running in the repo's "production" environment can assume the role.

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_repo != "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github_deploy" {
  count = var.github_repo != "" ? 1 : 0
  name  = "${var.app_name}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:environment:production"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  count = var.github_repo != "" ? 1 : 0
  name  = "${var.app_name}-release"
  role  = aws_iam_role.github_deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UploadReleases"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/releases/*"
      },
      {
        # Only instances tagged as this app, so it keeps working across instance replacement.
        Sid      = "RunUpdateOnAppInstance"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/App" = var.app_name }
        }
      },
      {
        # Only the stock run-a-script document.
        Sid      = "RunUpdateDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
      },
      {
        # Finding the instance and reading the command's result have no resource-level scoping.
        Sid      = "FindInstanceAndReadResult"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}
