# ---------------------------------------------------------------------------
# Multi-region CloudTrail trail (management events, all read + write)
# ---------------------------------------------------------------------------

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_logging                = true
  enable_log_file_validation    = true

  # Default event selector = management events, both Read and Write. We need:
  #   sts:GetCallerIdentity (global-ish, Read)  and/or
  #   ec2:DescribeAvailabilityZones (regional, Read)
  # Both are already covered by the default selector, so we leave it default.
  # If you only want the noise sources + nothing else (smaller scans), enable:
  # event_selector {
  #   include_management_events = true
  #   read_write_type           = "ReadOnly"
  #   data_resource {
  #     type   = "AWS::S3::Object"
  #     values = ["arn:aws:s3:::"]
  #   }
  # }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count             = 0 # Uncomment to stream trail events to CloudWatch Logs as well.
  name              = "/aws/cloudtrail/${var.project_prefix}-trail"
  retention_in_days = var.cloudtrail_log_retention_days
}
