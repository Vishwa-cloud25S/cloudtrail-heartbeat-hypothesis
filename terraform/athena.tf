# ---------------------------------------------------------------------------
# Athena + Glue: a partition-projection table over the CloudTrail logs.
# Partition projection means no crawler and no partition-loading Lambda — the
# partition layout is computed at query time. Keep `trail_regions` tight so
# scans only read the regions you care about.
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "cloudtrail" {
  name = var.glue_database_name
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = local.athena_bucket
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    expiration {
      days = var.cloudtrail_log_retention_days
    }
  }
}

# The standard CloudTrail Athena schema (same columns Sam's notebook reads).
resource "aws_glue_catalog_table" "cloudtrail" {
  name          = var.athena_table_name
  database_name = aws_glue_catalog_database.cloudtrail.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL"                 = "TRUE"
    "projection.enabled"       = "true"
    "projection.region.type"   = "enum"
    "projection.region.values" = join(",", var.trail_regions)
    # `NOW` in a partition-projection range is evaluated at query time, so new
    # partitions are picked up automatically. Keep the lower bound modest.
    "projection.year.type"    = "date"
    "projection.year.range"   = "2020/01/01,NOW"
    "projection.year.format"  = "yyyy"
    "projection.month.type"   = "date"
    "projection.month.range"  = "2020/01/01,NOW"
    "projection.month.format" = "MM"
    "projection.day.type"     = "date"
    "projection.day.range"    = "2020/01/01,NOW"
    "projection.day.format"   = "dd"
    # The $${...} form escapes interpolation so these stay literal placeholders
    # for the partition-projection values (region/year/month/day).
    "storage.location.template" = "s3://${aws_s3_bucket.cloudtrail.id}/${local.cloudtrail_prefix}/$${region}/$${year}/$${month}/$${day}/"
  }

  storage_descriptor {
    location = "s3://${aws_s3_bucket.cloudtrail.id}/${local.cloudtrail_prefix}"
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "eventversion"
      type = "string"
    }
    columns {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,accesskeyid:string,username:string,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>>>"
    }
    columns {
      name = "eventtime"
      type = "string"
    }
    columns {
      name = "eventsource"
      type = "string"
    }
    columns {
      name = "eventname"
      type = "string"
    }
    columns {
      name = "awsregion"
      type = "string"
    }
    columns {
      name = "sourceipaddress"
      type = "string"
    }
    columns {
      name = "useragent"
      type = "string"
    }
    columns {
      name = "errorcode"
      type = "string"
    }
    columns {
      name = "errormessage"
      type = "string"
    }
    columns {
      name = "requestparameters"
      type = "string"
    }
    columns {
      name = "responseelements"
      type = "string"
    }
    columns {
      name = "additionaleventdata"
      type = "string"
    }
    columns {
      name = "requestid"
      type = "string"
    }
    columns {
      name = "eventid"
      type = "string"
    }
    columns {
      name = "resources"
      type = "array<struct<arn:string,accountid:string,type:string>>"
    }
    columns {
      name = "eventtype"
      type = "string"
    }
    columns {
      name = "apiversion"
      type = "string"
    }
    columns {
      name = "readonly"
      type = "boolean"
    }
    columns {
      name = "recipientaccountid"
      type = "string"
    }
    columns {
      name = "vpcendpointid"
      type = "string"
    }
    columns {
      name = "useridentityinvokedby"
      type = "string"
    }
    columns {
      name = "tlsdetails"
      type = "struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>"
    }
    # `addendum` is non-null for the special "addendum" events CloudTrail emits
    # for the underlying files; Sam's notebook filters these out (`addendum is null`).
    columns {
      name = "addendum"
      type = "string"
    }
    columns {
      name = "managementevent"
      type = "boolean"
    }
    columns {
      name = "eventcategory"
      type = "string"
    }
  }

  partition_keys {
    name = "region"
    type = "string"
  }
  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}

# An Athena workgroup isolates query results and lets us cap scan cost.
resource "aws_athena_workgroup" "cloudtrail" {
  name = var.athena_workgroup_name
  configuration {
    enforce_workgroup_configuration = true
    engine_version {
      selected_engine_version = "3"
    }
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
    bytes_scanned_cutoff_per_query = 10737418240 # 10 GB hard cap per query
  }
}
