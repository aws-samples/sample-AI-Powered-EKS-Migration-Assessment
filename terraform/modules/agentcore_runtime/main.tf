###############################################################################
# Module: agentcore_runtime
# AgentCore Runtime - deployed via Docker container in ECR
# Pattern from: https://github.com/awslabs/agentcore-samples
###############################################################################

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = replace("${var.project_name}_runtime", "-", "_")
  description        = "EKS migration assessment agent v${var.deploy_version} using Strands Agents SDK"
  role_arn           = var.execution_role_arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${var.ecr_repository_url}:${var.image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    S3_BUCKET_NAME   = var.artifacts_bucket_name
    DYNAMODB_TABLE   = var.dynamodb_table_name
    AWS_REGION       = var.aws_region
    BEDROCK_MODEL_ID = var.bedrock_model_id
    MEMORY_ID        = var.memory_id
    LOG_LEVEL        = var.log_level
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-runtime"
  })
}
