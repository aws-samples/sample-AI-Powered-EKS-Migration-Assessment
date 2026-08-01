###############################################################################
# Module: iam
# AgentCore Runtime execution role and policies
###############################################################################

resource "aws_iam_role" "agentcore_execution" {
  name        = "${var.project_name}-agentcore-execution"
  description = "Execution role for AgentCore Runtime - allows Bedrock, S3, DynamoDB, CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-agentcore-execution"
    Purpose = "agentcore-runtime"
  })
}

# Bedrock model invocation
resource "aws_iam_role_policy" "agentcore_bedrock_invoke" {
  #tfsec:ignore:aws-iam-no-policy-wildcards - Bedrock model ARN requires wildcard for version (anthropic.claude-*)
  name = "bedrock-invoke"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockModelInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-*",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/us.anthropic.claude-*",
          "arn:aws:bedrock:us-*::foundation-model/anthropic.claude-*",
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:inference-profile/us.anthropic.claude-*"
        ]
      }
    ]
  })
}

# S3 - read application artifacts
resource "aws_iam_role_policy" "agentcore_s3_artifacts" {
  name = "s3-artifacts-read"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ArtifactsRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:HeadObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          var.artifacts_bucket_arn,
          "${var.artifacts_bucket_arn}/*"
        ]
      }
    ]
  })
}

# DynamoDB - write assessment results
resource "aws_iam_role_policy" "agentcore_dynamodb" {
  name = "dynamodb-assessments"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBAssessments"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*"
        ]
      }
    ]
  })
}

# CloudWatch Logs - observability
resource "aws_iam_role_policy" "agentcore_cloudwatch" {
  name = "cloudwatch-logs"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/bedrock-agentcore/*"
      }
    ]
  })
}

# ECR - pull agent container image
resource "aws_iam_role_policy" "agentcore_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"
      }
    ]
  })
}

# AgentCore Memory - read/write memory events
resource "aws_iam_role_policy" "agentcore_memory" {
  name = "agentcore-memory"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AgentCoreMemory"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetMemory",
          "bedrock-agentcore:CreateMemoryEvent",
          "bedrock-agentcore:ListMemoryEvents",
          "bedrock-agentcore:SearchMemory",
          "bedrock-agentcore:CreateSession",
          "bedrock-agentcore:GetSession",
          "bedrock-agentcore:ListSessions"
        ]
        Resource = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.aws_account_id}:memory/*"
      }
    ]
  })
}

# KMS - decrypt S3 objects and DynamoDB items
resource "aws_iam_role_policy" "agentcore_kms" {
  name = "kms-decrypt"
  role = aws_iam_role.agentcore_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}
