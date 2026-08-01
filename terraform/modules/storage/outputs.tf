###############################################################################
# Module: storage
# Outputs
###############################################################################

output "artifacts_bucket_id" {
  description = "S3 artifacts bucket name"
  value       = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  description = "S3 artifacts bucket ARN"
  value       = aws_s3_bucket.artifacts.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB assessments table name"
  value       = aws_dynamodb_table.assessments.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB assessments table ARN"
  value       = aws_dynamodb_table.assessments.arn
}
