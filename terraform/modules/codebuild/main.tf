###############################################################################
# Module: codebuild
# AWS CodeBuild projects to build and push Docker images to ECR
# Triggered automatically during terraform apply via null_resource
###############################################################################

###############################################################################
# IAM Role for CodeBuild
###############################################################################

resource "aws_iam_role" "codebuild" {
  name        = "${var.project_name}-codebuild"
  description = "CodeBuild role for building and pushing Docker images"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "codebuild" {
  name = "codebuild-permissions"
  role = aws_iam_role.codebuild.id

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
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"
      },
      {
        Sid    = "S3Source"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.source_bucket_name}",
          "arn:aws:s3:::${var.source_bucket_name}/*"
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [var.kms_key_arn]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/*"
      }
    ]
  })
}

###############################################################################
# CodeBuild Project - Agent Image
###############################################################################

resource "aws_codebuild_project" "agent" {
  name          = "${var.project_name}-agent-build"
  description   = "Builds and pushes the EKS migration assessment agent Docker image"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true  # Required for Docker builds

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.agent_ecr_repository_url
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = var.agent_source_hash
    }
  }

  source {
    type      = "S3"
    location  = "${var.source_bucket_name}/builds/agent-source.zip"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - echo Logging in to Amazon ECR...
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
        build:
          commands:
            - echo Building Docker image with tag $IMAGE_TAG...
            - docker build -t $ECR_REPO_URL:latest -t $ECR_REPO_URL:$IMAGE_TAG .
        post_build:
          commands:
            - echo Pushing Docker image...
            - docker push $ECR_REPO_URL:latest
            - docker push $ECR_REPO_URL:$IMAGE_TAG
            - echo Build complete. Tag=$IMAGE_TAG
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-agent-build"
      stream_name = "build"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-agent-build"
  })
}

###############################################################################
# CodeBuild Project - UI Image
###############################################################################

resource "aws_codebuild_project" "ui" {
  name          = "${var.project_name}-ui-build"
  description   = "Builds and pushes the EKS migration assessment UI Docker image"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ui_ecr_repository_url
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }
  }

  source {
    type      = "S3"
    location  = "${var.source_bucket_name}/builds/ui-source.zip"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
        build:
          commands:
            - docker build -t $ECR_REPO_URL:latest .
        post_build:
          commands:
            - docker push $ECR_REPO_URL:latest
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-ui-build"
      stream_name = "build"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-ui-build"
  })
}

###############################################################################
# Upload source code to S3 and trigger builds via null_resource
# Source zips are uploaded by deploy.sh BEFORE terraform apply
# Terraform just triggers the builds — no local file references needed
###############################################################################

# Trigger agent build and wait for completion
resource "null_resource" "build_agent" {
  triggers = {
    source_hash = sha256(var.agent_source_hash)
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Starting agent CodeBuild..."
      BUILD_ID=$(aws codebuild start-build \
        --project-name ${aws_codebuild_project.agent.name} \
        --region ${var.aws_region} \
        --query 'build.id' --output text)
      echo "Build ID: $BUILD_ID"

      # Wait for build to complete
      while true; do
        STATUS=$(aws codebuild batch-get-builds \
          --ids "$BUILD_ID" \
          --region ${var.aws_region} \
          --query 'builds[0].buildStatus' --output text)
        echo "Agent build status: $STATUS"
        if [ "$STATUS" = "SUCCEEDED" ]; then
          echo "Agent build succeeded."
          break
        elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "FAULT" ] || [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "TIMED_OUT" ]; then
          echo "Agent build failed with status: $STATUS"
          exit 1
        fi
        sleep 15
      done
    EOT
  }

  depends_on = [aws_codebuild_project.agent]
}

# Trigger UI build and wait for completion
resource "null_resource" "build_ui" {
  triggers = {
    source_hash = sha256(var.ui_source_hash)
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Starting UI CodeBuild..."
      BUILD_ID=$(aws codebuild start-build \
        --project-name ${aws_codebuild_project.ui.name} \
        --region ${var.aws_region} \
        --query 'build.id' --output text)
      echo "Build ID: $BUILD_ID"

      while true; do
        STATUS=$(aws codebuild batch-get-builds \
          --ids "$BUILD_ID" \
          --region ${var.aws_region} \
          --query 'builds[0].buildStatus' --output text)
        echo "UI build status: $STATUS"
        if [ "$STATUS" = "SUCCEEDED" ]; then
          echo "UI build succeeded."
          break
        elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "FAULT" ] || [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "TIMED_OUT" ]; then
          echo "UI build failed with status: $STATUS"
          exit 1
        fi
        sleep 15
      done
    EOT
  }

  depends_on = [aws_codebuild_project.ui]
}
