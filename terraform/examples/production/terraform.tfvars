# Production deployment configuration
# Copy from terraform.tfvars.example and update for your environment

aws_region          = ""  # Region of deployment
environment         = ""  # deployment environment
project_name        = ""
vpc_cidr            = "" # CIDR of VPC
bedrock_model_id    = "<your-preferred-model-id>" # Model ID
log_level           = "INFO"
ecs_desired_count   = 2  # Provide number of replica task for UI
allowed_cidr_blocks      = [""]  # Optional
allowed_ipv6_cidr_blocks = [""]  # Optional
# Authentication: (true/fales) set to true for production (requires Cognito User Pool login)
enable_cognito_auth = true


