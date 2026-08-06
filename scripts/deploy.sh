#!/bin/bash
###############################################################################
# End-to-End Deployment Script
#
# Docker images are built in AWS CodeBuild — no local Docker needed.
#
# Deploy order:
#   1. Package source code zips (agent + UI)
#   2. Deploy all infrastructure via Terraform
#      - CodeBuild builds and pushes Docker images to ECR automatically
#      - AgentCore Runtime is created after images are ready
###############################################################################

set -euo pipefail

# Disable AWS CLI pager (prevents output getting stuck in 'less')
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform/examples/production"
SRC_DIR="${PROJECT_ROOT}/src"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

###############################################################################
# Pre-flight checks
###############################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=()
    command -v terraform >/dev/null 2>&1 || missing+=("terraform")
    command -v aws >/dev/null 2>&1       || missing+=("aws-cli")
    command -v zip >/dev/null 2>&1       || missing+=("zip")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        exit 1
    fi

    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi

    # Validate project_name from tfvars (must be valid for S3 bucket naming)
    local PROJECT_NAME
    PROJECT_NAME=$(grep -E '^\s*project_name\s*=' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "")
    if [ -n "${PROJECT_NAME}" ]; then
        if ! echo "${PROJECT_NAME}" | grep -qE '^[a-z0-9][a-z0-9\-]{1,40}[a-z0-9]$'; then
            log_error "Invalid project_name '${PROJECT_NAME}' in terraform.tfvars"
            log_error "Must be lowercase alphanumeric and hyphens only (3-42 chars), e.g. 'eks-migration-agent'"
            log_error "No spaces, underscores, or uppercase letters allowed (S3 bucket naming rules)."
            exit 1
        fi
    fi

    log_info "All prerequisites met."
}

###############################################################################
# Package and upload source code to S3 for CodeBuild
###############################################################################

package_and_upload_sources() {
    log_info "Packaging source code..."

    if [ ! -d "${SRC_DIR}/agent" ]; then
        log_error "Source directory not found: ${SRC_DIR}/agent"
        log_error "Ensure the repository was cloned completely."
        exit 1
    fi
    if [ ! -d "${SRC_DIR}/ui" ]; then
        log_error "Source directory not found: ${SRC_DIR}/ui"
        log_error "Ensure the repository was cloned completely."
        exit 1
    fi

    # Package agent source
    cd "${SRC_DIR}/agent"
    zip -q -r "${SRC_DIR}/agent-source.zip" . --exclude "*.pyc" --exclude "__pycache__/*"
    cd "${PROJECT_ROOT}"

    # Package UI source
    cd "${SRC_DIR}/ui"
    zip -q -r "${SRC_DIR}/ui-source.zip" . --exclude "*.pyc" --exclude "__pycache__/*"
    cd "${PROJECT_ROOT}"

    log_info "Source zips created at ${SRC_DIR}/"
}

###############################################################################
# Deploy all infrastructure (two-phase: S3 first, then full apply)
###############################################################################

deploy_infrastructure() {
    log_info "Deploying infrastructure with Terraform..."
    cd "${TERRAFORM_DIR}"
    terraform init -upgrade -input=false

    # Phase 1: Create S3 bucket first (if not already exists)
    # Storage depends on KMS, so we must target both modules
    local BUCKET
    BUCKET=$(terraform output -raw s3_artifacts_bucket 2>/dev/null || echo "")
    if [ -z "${BUCKET}" ]; then
        log_info "Phase 1: Creating KMS + S3 bucket first..."
        terraform apply -target=module.kms -target=module.storage -auto-approve
        BUCKET=$(terraform output -raw s3_artifacts_bucket)
        if [ -z "${BUCKET}" ]; then
            log_error "Failed to create S3 bucket. Check your AWS credentials and project_name value."
            log_error "project_name must be lowercase alphanumeric and hyphens only (e.g. 'eks-migration-agent')."
            exit 1
        fi
        log_info "S3 bucket created: ${BUCKET}"
    fi

    # Upload source zips to S3 (now bucket guaranteed to exist)
    log_info "Uploading source zips to S3..."
    aws s3 cp "${SRC_DIR}/agent-source.zip" "s3://${BUCKET}/builds/agent-source.zip"
    aws s3 cp "${SRC_DIR}/ui-source.zip" "s3://${BUCKET}/builds/ui-source.zip"
    log_info "Source zips uploaded to s3://${BUCKET}/builds/"

    # Phase 2: Full apply
    terraform plan -out=tfplan

    echo ""
    echo -e "${YELLOW}Review the plan above.${NC}"
    read -p "Do you want to apply this plan? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Deployment aborted by user."
        rm -f tfplan
        exit 0
    fi

    log_info "Applying Terraform plan..."
    log_info "CodeBuild will build Docker images in AWS (this takes ~5-10 minutes)..."
    terraform apply tfplan
    rm -f tfplan

    # Force ECS to pull latest UI image
    log_info "Forcing ECS new deployment..."
    local CLUSTER SERVICE_NAME AWS_REGION_VAL
    CLUSTER=$(terraform output -raw ecs_cluster_name 2>/dev/null || echo "")
    AWS_REGION_VAL=$(grep -E '^\s*aws_region\s*=' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "${AWS_REGION:-us-east-1}")
    if [ -n "${CLUSTER}" ]; then
        SERVICE_NAME="${CLUSTER%-cluster}-ui"
        aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE_NAME}" --force-new-deployment --region "${AWS_REGION_VAL}" >/dev/null 2>&1 || true
        log_info "ECS service ${SERVICE_NAME} force-deployed."
    fi

    log_info "Infrastructure deployed."
    cd "${PROJECT_ROOT}"
}

###############################################################################
# Create test Cognito user
###############################################################################

create_test_user() {
    cd "${TERRAFORM_DIR}"
    local POOL_ID
    POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "")
    cd "${PROJECT_ROOT}"

    if [ -z "${POOL_ID}" ]; then
        log_warn "No Cognito User Pool found - skipping test user creation."
        return
    fi

    # User must provide credentials via environment variables
    local TEST_EMAIL="${TEST_USER_EMAIL:-}"
    local TEST_PASSWORD="${TEST_USER_PASSWORD:-}"

    if [ -z "${TEST_EMAIL}" ]; then
        read -p "Enter email for Cognito test user (or press Enter to skip): " TEST_EMAIL
        if [ -z "${TEST_EMAIL}" ]; then
            log_warn "Skipping test user creation. Create users manually via AWS Console or CLI."
            return
        fi
    fi

    if [ -z "${TEST_PASSWORD}" ]; then
        read -sp "Enter temporary password (min 12 chars, upper+lower+number+symbol): " TEST_PASSWORD
        echo ""
        if [ -z "${TEST_PASSWORD}" ]; then
            log_warn "No password provided. Skipping test user creation."
            return
        fi
    fi

    aws cognito-idp admin-create-user \
        --user-pool-id "${POOL_ID}" \
        --username "${TEST_EMAIL}" \
        --user-attributes Name=email,Value="${TEST_EMAIL}" Name=email_verified,Value=true \
        --temporary-password "${TEST_PASSWORD}" \
        --message-action SUPPRESS 2>/dev/null || true

    # Set permanent password (skip forced change on first login)
    aws cognito-idp admin-set-user-password \
        --user-pool-id "${POOL_ID}" \
        --username "${TEST_EMAIL}" \
        --password "${TEST_PASSWORD}" \
        --permanent \
        --region "${AWS_REGION:-us-east-1}" 2>/dev/null || true

    log_info "Test user created: ${TEST_EMAIL} (password set, ready to login)"
}

###############################################################################
# Main
###############################################################################

main() {
    log_info "=========================================="
    log_info " EKS Migration Assessment Agent Deployer"
    log_info "=========================================="

    check_prerequisites
    package_and_upload_sources  # Zip and upload source to S3
    deploy_infrastructure      # Terraform deploys all + CodeBuild builds images
    create_test_user

    log_info "=========================================="
    log_info " Deployment Complete!"
    log_info "=========================================="

    cd "${TERRAFORM_DIR}"
    local UI_URL RUNTIME_ID
    UI_URL=$(terraform output -raw ui_url 2>/dev/null || echo "http://<alb-dns>")
    RUNTIME_ID=$(terraform output -raw agent_runtime_id 2>/dev/null || echo "<runtime-id>")
    cd "${PROJECT_ROOT}"

    log_info ""
    log_info "UI URL (open in browser):"
    log_info "  ${UI_URL}"
    log_info ""
    log_info "Or invoke agent directly:"
    log_info "  python scripts/invoke_agent.py --runtime-id ${RUNTIME_ID} --app-name my-app --s3-prefix assessments/my-app/"
    log_info ""
}

main "$@"
