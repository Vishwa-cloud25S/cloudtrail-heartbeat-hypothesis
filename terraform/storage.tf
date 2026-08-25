# ---------------------------------------------------------------------------
# Storage: the CloudTrail delivery bucket + the Athena results bucket
# ---------------------------------------------------------------------------

locals {
  cloudtrail_bucket = coalesce(var.cloudtrail_bucket_name, "${var.project_prefix}-cloudtrail-${data.aws_caller_identity.current.account_id}")
  athena_bucket     = coalesce(var.athena_results_bucket_name, "${var.project_prefix}-athena-${data.aws_caller_identity.current.account_id}")
  // CloudTrail's default object layout inside the bucket:
  cloudtrail_prefix = "AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail"
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = local.cloudtrail_bucket
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

# CloudTrail ignores SSE-KMS object policies; SSE-S3 (AES256) keeps this simple
# and avoids a whole extra KMS key + policy. Upgrade to KMS if you need it.
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Expire old logs to keep Athena scans + storage cost near zero.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    id     = "expire-cloudtrail-logs"
    status = "Enabled"
    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 15
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.cloudtrail_log_retention_days
    }
  }
}

# CloudTrail refuses to write unless the bucket policy explicitly permits it.
# We scope to our own account with the AWS-recommended SourceArn/SourceAccount
# conditions.
data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  statement {
    sid    = "CloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_prefix}-trail"]
    }
  }
  statement {
    sid    = "CloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/${local.cloudtrail_prefix}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_prefix}-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy.json
}
