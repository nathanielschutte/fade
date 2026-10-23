# The health monitor (docs/health-monitor.md): a Lambda every 5 minutes checks
# /api/health from outside, gathers evidence when it fails, tries to fix the
# server (restart the app, reboot, stop/start), records each incident in the
# artifacts bucket under health/, and notifies the SNS topic. Free-tier sized.

data "archive_file" "health" {
  type        = "zip"
  source_file = "${path.module}/health/monitor.py"
  output_path = "${path.module}/.build/health.zip"
}

variable "health_act" {
  description = "Let the health monitor act (restart, reboot, stop/start). false: watch and report only."
  type        = bool
  default     = true
}

resource "aws_sns_topic" "health" {
  name = "${var.app_name}-health"
}

resource "aws_cloudwatch_log_group" "health" {
  name              = "/aws/lambda/${var.app_name}-health"
  retention_in_days = 14
}

resource "aws_iam_role" "health" {
  name = "${var.app_name}-health"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "health" {
  name = "${var.app_name}-health"
  role = aws_iam_role.health.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Look"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:GetConsoleOutput",
          "ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
      {
        # Only on this app's server; no terminate, no delete of any kind.
        Sid       = "Act"
        Effect    = "Allow"
        Action    = ["ec2:RebootInstances", "ec2:StopInstances", "ec2:StartInstances", "ssm:SendCommand"]
        Resource  = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/App" = var.app_name } }
      },
      {
        Sid      = "RestartDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
      },
      {
        Sid      = "Record"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/health/*"
      },
      {
        # So a missing state file reads as "not found", not "access denied".
        Sid       = "RecordList"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.artifacts.arn
        Condition = { StringLike = { "s3:prefix" = ["health/*"] } }
      },
      {
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.health.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.health.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "health" {
  function_name    = "${var.app_name}-health"
  description      = "napsack health monitor (docs/health-monitor.md)"
  role             = aws_iam_role.health.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "monitor.handler"
  filename         = data.archive_file.health.output_path
  source_code_hash = data.archive_file.health.output_base64sha256
  timeout          = 60
  memory_size      = 128
  environment {
    variables = {
      HEALTH_URL = "https://${local.domain}/api/health"
      APP_TAG    = var.app_name
      BUCKET     = aws_s3_bucket.artifacts.id
      TOPIC_ARN  = aws_sns_topic.health.arn
      ACT        = var.health_act ? "true" : "false"
    }
  }
  depends_on = [aws_cloudwatch_log_group.health, aws_iam_role_policy.health]
}

resource "aws_cloudwatch_event_rule" "health" {
  name                = "${var.app_name}-health"
  description         = "Run the health monitor every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "health" {
  rule = aws_cloudwatch_event_rule.health.name
  arn  = aws_lambda_function.health.arn
}

resource "aws_lambda_permission" "health" {
  statement_id  = "every-five-minutes"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health.arn
}

output "health_topic_arn" {
  description = "Subscribe to health notifications: aws sns subscribe --topic-arn <this> --protocol email --notification-endpoint you@example.com"
  value       = aws_sns_topic.health.arn
}
