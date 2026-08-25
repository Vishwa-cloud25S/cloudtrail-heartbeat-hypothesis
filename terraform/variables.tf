variable "project_prefix" {
  description = "Prefix used to name AWS resources. Change to a value that is unique in your account."
  type        = string
  default     = "tracebit-ct-heartbeat"
}

variable "aws_region" {
  description = "Home region for the multi-region CloudTrail trail + S3 bucket + Athena (also your 'busy' region)."
  type        = string
  default     = "us-east-1"
}

variable "quiet_region" {
  description = "The 'inactive' region you use almost never. This is where the heartbeat noise is injected."
  type        = string
  default     = "eu-west-2"
}

# --- CloudTrail / storage ---------------------------------------------------

variable "cloudtrail_bucket_name" {
  description = "Name of the S3 bucket CloudTrail writes to. Leave null to generate one from the prefix."
  type        = string
  default     = null
}

variable "athena_results_bucket_name" {
  description = "Name of the S3 bucket used for Athena query results. Leave null to generate one."
  type        = string
  default     = null
}

variable "trail_regions" {
  description = "Regions CloudTrail covers. Used to restrict Athena partition projection so scans stay cheap."
  type        = list(string)
  default     = ["us-east-1", "eu-west-2"]
}

variable "cloudtrail_log_retention_days" {
  description = "Days to keep CloudTrail logs / Athena results in S3 before they expire."
  type        = number
  default     = 30
}

# --- Athena / Glue ----------------------------------------------------------

variable "glue_database_name" {
  description = "Name of the Glue / Athena database for the CloudTrail table."
  type        = string
  default     = "cloudtrail_latency"
}

variable "athena_table_name" {
  description = "Name of the Athena table over the CloudTrail logs."
  type        = string
  default     = "cloudtrail_logs"
}

variable "athena_workgroup_name" {
  description = "Name of the Athena workgroup (isolates query results + sets scan-cost guardrails)."
  type        = string
  default     = "cloudtrail-latency"
}

# --- Heartbeat Lambda -------------------------------------------------------

variable "heartbeat_regions" {
  description = "Regions the heartbeat Lambda injects noise into. Default is just the quiet region."
  type        = list(string)
  default     = ["eu-west-2"]
}

variable "heartbeat_methods" {
  description = "Comma-separated API calls the heartbeat issues (colon = service:method)."
  type        = string
  default     = "sts:GetCallerIdentity,ec2:DescribeAvailabilityZones"
}

variable "heartbeat_interval_seconds" {
  description = "Spacing between heartbeat calls. EventBridge Scheduler's minimum is 60s, so the Lambda issues this many heartbeats per 60s invocation to emulate 30s."
  type        = number
  default     = 30
}

variable "heartbeats_per_invocation" {
  description = "How many heartbeat passes per 60s scheduler invocation (2 x 30s = a 30s cadence)."
  type        = number
  default     = 2
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout. Must stay under the scheduler period (60s) to avoid overlapping invocations."
  type        = number
  default     = 55
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project = "tracebit-cloudtrail-latency"
    purpose = "test Sam Cox's inactive-region background-noise hypothesis"
  }
}
