###############################################################################
# Module: iam
# ECS task execution role and task role (UI container)
###############################################################################

###############################################################################
# ECS Task Execution Role - pulls images, writes logs (AWS managed)
###############################################################################

resource "aws_iam_role" "ecs_task_execution" {
  name        = "${var.project_name}-ecs-task-execution"
  description = "ECS task execution role - ECR pull and CloudWatch Logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-ecs-task-execution"
    Purpose = "ecs-task-execution"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

###############################################################################
# ECS Task Role - what the running UI container can do at runtime
###############################################################################

resource "aws_iam_role" "ecs_task" {
  name        = "${var.project_name}-ecs-task"
  description = "ECS task role - AgentCore invoke, S3 upload, DynamoDB read"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-ecs-task"
    Purpose = "ecs-task-runtime"
  })
}

# Invoke AgentCore Runtime directly (no API Gateway needed)
resource "aws_iam_role_policy" "ecs_task_agentcore_invoke" {
  name = "agentcore-invoke"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AgentCoreInvoke"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:InvokeAgentRuntime",
          "bedrock-agentcore:InvokeAgentRuntimeStream"
        ]
        Resource = "*"
      }
    ]
  })
}

# S3 - upload and read application artifacts
resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "s3-artifacts"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ArtifactsReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          var.artifacts_bucket_arn,
          "${var.artifacts_bucket_arn}/*"
        ]
      },
      {
        Sid    = "KMSForS3"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

# DynamoDB - read assessment history for UI display
resource "aws_iam_role_policy" "ecs_task_dynamodb" {
  name = "dynamodb-read"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:GetItem"
        ]
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*"
        ]
      }
    ]
  })
}

# Cognito - app-level authentication (only needed when Cognito enabled)
resource "aws_iam_role_policy" "ecs_task_cognito" {
  name = "cognito-auth"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CognitoAuth"
        Effect = "Allow"
        Action = [
          "cognito-idp:InitiateAuth",
          "cognito-idp:RespondToAuthChallenge"
        ]
        Resource = "arn:aws:cognito-idp:${var.aws_region}:${var.aws_account_id}:userpool/*"
      }
    ]
  })
}
