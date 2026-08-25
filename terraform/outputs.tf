output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.id
}

output "cloudtrail_prefix" {
  value = local.cloudtrail_prefix
}

output "cloudtrail_trail_name" {
  value = aws_cloudtrail.main.name
}

output "athena_database" {
  value = aws_glue_catalog_database.cloudtrail.name
}

output "athena_table" {
  value = aws_glue_catalog_table.cloudtrail.name
}

output "athena_workgroup" {
  value = aws_athena_workgroup.cloudtrail.name
}

output "heartbeat_lambda_arn" {
  value = aws_lambda_function.heartbeat.arn
}

output "heartbeat_schedule_arn" {
  value = aws_scheduler_schedule.heartbeat.arn
}
