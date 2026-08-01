###############################################################################
# Module: cognito
# Cognito User Pool + App Client for UI authentication
#
# Auth flow:
#   Browser → ALB (HTTPS) → Cognito hosted UI → JWT token
#   ALB validates JWT on every request before forwarding to ECS
#   ECS task uses IAM role (IRSA-style) to call AgentCore - no Cognito needed there
#
# AgentCore Runtime uses IAM auth (SigV4) - Cognito is only for the UI layer
###############################################################################

resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-users"

  # Password policy
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # Self-registration disabled - admin creates users
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # MFA optional (set to "ON" for production)
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # User attributes
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  auto_verified_attributes = ["email"]

  # Token validity
  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-user-pool"
  })
}

# User Pool Domain (for hosted UI)
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project_name}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# App Client - used by ALB for OAuth2 code flow
resource "aws_cognito_user_pool_client" "alb" {
  name         = "${var.project_name}-alb-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # ALB uses authorization_code flow
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Callback URLs - ALB OAuth2 endpoint (HTTPS required by Cognito)
  callback_urls = [
    "https://${var.alb_dns_name}/oauth2/idpresponse"
  ]

  logout_urls = [
    "https://${var.alb_dns_name}/logout"
  ]

  supported_identity_providers = ["COGNITO"]

  # Token validity
  access_token_validity  = 1   # hours
  id_token_validity      = 1   # hours
  refresh_token_validity = 30  # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Do not generate client secret (required for USER_PASSWORD_AUTH from app)
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}
