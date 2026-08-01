###############################################################################
# Module: storage
# S3 artifacts bucket + DynamoDB table
###############################################################################

###############################################################################
# S3 - Application Artifacts (uploaded by UI for assessment)
###############################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project_name}-artifacts-${var.aws_account_id}"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-artifacts"
    Purpose = "application-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# DynamoDB - Assessment Results
###############################################################################

resource "aws_dynamodb_table" "assessments" {
  name         = "${var.project_name}-assessments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "assessment_id"

  attribute {
    name = "assessment_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  attribute {
    name = "app_name"
    type = "S"
  }

  global_secondary_index {
    name            = "app-name-index"
    hash_key        = "app_name"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-assessments"
  })
}
