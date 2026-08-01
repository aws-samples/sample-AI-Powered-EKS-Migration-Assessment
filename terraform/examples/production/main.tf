###############################################################################
# Root: examples/production
# Orchestrates all modules
#
# Architecture:
#   Browser → ALB → [Cognito JWT] → ECS Fargate (Streamlit UI)
#   ECS → AgentCore Runtime (IAM/SigV4) → Strands Agent (tools run in-process)
#   Strands Agent → AgentCore Memory (short-term + long-term)
#   Strands Agent → S3 (read artifacts) + DynamoDB (persist results)
#
# Tools run INSIDE the Strands agent process — no Lambda/Gateway needed.
###############################################################################

###############################################################################
# 1. KMS — Customer Managed Key for encryption at rest
###############################################################################

module "kms" {
  source = "../../modules/kms"

  project_name   = var.project_name
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
}

###############################################################################
# 2. Networking — VPC, subnets, SGs
###############################################################################

module "networking" {
  source = "../../modules/networking"

  project_name             = var.project_name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  allowed_cidr_blocks      = var.allowed_cidr_blocks
  allowed_ipv6_cidr_blocks = var.allowed_ipv6_cidr_blocks
}

###############################################################################
# 2. Storage — S3 (artifacts + agent code) + DynamoDB
###############################################################################

module "storage" {
  source = "../../modules/storage"

  project_name   = var.project_name
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
  kms_key_arn    = module.kms.key_arn

  depends_on = [module.kms]
}

###############################################################################
# 3. ECR — container image repositories (agent + UI)
###############################################################################

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = var.environment
}

###############################################################################
# 4. IAM — all roles and policies
###############################################################################

module "iam" {
  source = "../../modules/iam"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  aws_account_id       = data.aws_caller_identity.current.account_id
  bedrock_model_id     = var.bedrock_model_id
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn
  dynamodb_table_arn   = module.storage.dynamodb_table_arn
  kms_key_arn          = module.kms.key_arn
}

###############################################################################
# 5. CodeBuild — builds Docker images in AWS and pushes to ECR
#    No local Docker needed. Triggered automatically during terraform apply.
###############################################################################

module "codebuild" {
  source = "../../modules/codebuild"

  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  aws_account_id           = data.aws_caller_identity.current.account_id
  agent_ecr_repository_url = module.ecr.agent_repository_url
  ui_ecr_repository_url    = module.ecr.ui_repository_url
  source_bucket_name       = module.storage.artifacts_bucket_id
  kms_key_arn              = module.kms.key_arn
  agent_source_hash        = fileexists("${path.module}/../../../src/agent-source.zip") ? filemd5("${path.module}/../../../src/agent-source.zip") : "initial"
  ui_source_hash           = fileexists("${path.module}/../../../src/ui-source.zip") ? filemd5("${path.module}/../../../src/ui-source.zip") : "initial"

  depends_on = [module.ecr, module.storage, module.iam]
}

###############################################################################
# 6. AgentCore Memory — persistent memory for cross-session context
###############################################################################

module "agentcore_memory" {
  source = "../../modules/agentcore_memory"

  project_name       = var.project_name
  environment        = var.environment
  execution_role_arn = module.iam.agentcore_execution_role_arn
  event_expiry_days  = 90

  depends_on = [module.iam]
}

###############################################################################
# 7. AgentCore Runtime — container deployment (image built by CodeBuild)
###############################################################################

module "agentcore_runtime" {
  source = "../../modules/agentcore_runtime"

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = var.aws_region
  execution_role_arn    = module.iam.agentcore_execution_role_arn
  ecr_repository_url    = module.ecr.agent_repository_url
  bedrock_model_id      = var.bedrock_model_id
  artifacts_bucket_name = module.storage.artifacts_bucket_id
  dynamodb_table_name   = module.storage.dynamodb_table_name
  memory_id             = module.agentcore_memory.memory_id
  log_level             = var.log_level
  image_tag             = "latest"
  deploy_version        = fileexists("${path.module}/../../../src/agent-source.zip") ? substr(filemd5("${path.module}/../../../src/agent-source.zip"), 0, 8) : "1"

  # Must wait for CodeBuild to push the image before creating the runtime
  depends_on = [module.iam, module.storage, module.agentcore_memory, module.codebuild]
}

###############################################################################
# 7. AgentCore Endpoint — invoke URL for the UI to call the agent
###############################################################################

module "agentcore_endpoint" {
  source = "../../modules/agentcore_endpoint"

  project_name     = var.project_name
  environment      = var.environment
  agent_runtime_id = module.agentcore_runtime.runtime_id

  depends_on = [module.agentcore_runtime]
}

###############################################################################
# 7. ECS UI — Fargate + ALB (no Cognito for initial deploy/testing)
#    Cognito auth can be added after first successful deploy
###############################################################################

module "ecs_ui" {
  source = "../../modules/ecs_ui"

  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  vpc_id                   = module.networking.vpc_id
  public_subnet_ids        = module.networking.public_subnet_ids
  private_subnet_ids       = module.networking.private_subnet_ids
  alb_security_group_id    = module.networking.alb_security_group_id
  ecs_ui_security_group_id = module.networking.ecs_ui_security_group_id
  task_execution_role_arn  = module.iam.ecs_task_execution_role_arn
  task_role_arn            = module.iam.ecs_task_role_arn
  ecr_ui_repository_url   = module.ecr.ui_repository_url
  agent_runtime_id        = module.agentcore_runtime.runtime_id
  agent_endpoint_id       = module.agentcore_endpoint.endpoint_id
  artifacts_bucket_name   = module.storage.artifacts_bucket_id
  dynamodb_table_name     = module.storage.dynamodb_table_name
  desired_count           = var.ecs_desired_count
  kms_key_arn             = module.kms.key_arn
  enable_cognito_auth     = var.enable_cognito_auth
  cognito_user_pool_arn       = var.enable_cognito_auth ? module.cognito[0].user_pool_arn : ""
  cognito_user_pool_client_id = var.enable_cognito_auth ? module.cognito[0].app_client_id : ""
  cognito_user_pool_domain    = var.enable_cognito_auth ? module.cognito[0].hosted_ui_domain : ""

  depends_on = [module.networking, module.iam, module.ecr, module.agentcore_runtime, module.agentcore_endpoint, module.codebuild]
}

###############################################################################
# 9. Cognito — User authentication for UI (optional, controlled by variable)
###############################################################################

module "cognito" {
  source = "../../modules/cognito"
  count  = var.enable_cognito_auth ? 1 : 0

  project_name = var.project_name
  environment  = var.environment
  alb_dns_name = module.ecs_ui.alb_dns_name

  tags = {}
}

###############################################################################
# 10. WAF — Protects ALB with rate limiting and managed rules
###############################################################################

module "waf" {
  source = "../../modules/waf"

  project_name = var.project_name
  alb_arn      = module.ecs_ui.alb_arn

  depends_on = [module.ecs_ui]
}
