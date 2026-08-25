# ---------------------------------------------------------------------------
# The heartbeat: a tiny Lambda invoked by EventBridge Scheduler that keeps a
# constant trickle of CloudTrail events in the quiet region(s).
# ---------------------------------------------------------------------------

data "archive_file" "heartbeat" {
  type        = "zip"
  source_file = "${path.module}/../heartbeat/lambda/heartbeat.py"
  output_path = "${path.module}/.terraform/heartbeat_payload.zip"
}

# --- IAM ---------------------------------------------------------------------

resource "aws_iam_role" "heartbeat" {
  name = "${var.project_prefix}-heartbeat-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "heartbeat" {
  name = "${var.project_prefix}-heartbeat-policy"
  role = aws_iam_role.heartbeat.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CallRegionalApisForNoise"
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeRegions",
        ]
        Resource = "*"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

resource "aws_lambda_function" "heartbeat" {
  function_name    = "${var.project_prefix}-heartbeat"
  role             = aws_iam_role.heartbeat.arn
  handler          = "heartbeat.handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout_seconds
  memory_size      = 128
  filename         = data.archive_file.heartbeat.output_path
  source_code_hash = data.archive_file.heartbeat.output_base64sha256

  environment {
    variables = {
      HEARTBEAT_REGIONS          = join(",", var.heartbeat_regions)
      HEARTBEAT_METHODS          = var.heartbeat_methods
      HEARTBEAT_INTERVAL_SECONDS = tostring(var.heartbeat_interval_seconds)
      HEARTBEATS_PER_INVOCATION  = tostring(var.heartbeats_per_invocation)
    }
  }
}

# CloudWatch logs for the Lambda.
resource "aws_cloudwatch_log_group" "heartbeat" {
  name              = "/aws/lambda/${var.project_prefix}-heartbeat"
  retention_in_days = var.cloudtrail_log_retention_days
}

# --- Scheduling --------------------------------------------------------------

# Scheduler needs an execution role that can invoke the Lambda.
resource "aws_iam_role" "heartbeat_scheduler" {
  name = "${var.project_prefix}-heartbeat-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "heartbeat_scheduler" {
  name = "${var.project_prefix}-heartbeat-scheduler-policy"
  role = aws_iam_role.heartbeat_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["lambda:InvokeFunction"]
      Effect   = "Allow"
      Resource = aws_lambda_function.heartbeat.arn
    }]
  })
}

# Allow Scheduler (under a fresh execution role) to invoke the function.
resource "aws_lambda_permission" "heartbeat_scheduler" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.heartbeat.arn
}

# Rate(1 minute) — the minimum supported by EventBridge Scheduler. The Lambda
# runs HEARTBEATS_PER_INVOCATION (2) passes spaced HEARTBEAT_INTERVAL_SECONDS
# (30s) apart, giving an effective 30s cadence.
#
# state = DISABLED so the baseline (noise-OFF) window is clean. Enable it by
# hand once the baseline has accumulated:
#     aws scheduler start-schedule --name <prefix>-heartbeat-schedule
resource "aws_scheduler_schedule" "heartbeat" {
  name                = "${var.project_prefix}-heartbeat-schedule"
  description         = "Inject periodic CloudTrail noise into quiet regions to test Tracebit's delivery-latency hypothesis"
  state               = "DISABLED"
  schedule_expression = "rate(1 minute)"
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.heartbeat.arn
    role_arn = aws_iam_role.heartbeat_scheduler.arn
    input    = jsonencode({})
  }
}
