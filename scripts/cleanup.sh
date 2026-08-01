#!/bin/bash
###############################################################################
# Cleanup Script
# - Empties all S3 buckets (including versioned objects)
# - Deletes all ECR images
# - Runs terraform destroy
# - Removes all local state, lock, and build files
###############################################################################

set -euo pipefail

# Disable AWS CLI pager (prevents output getting stuck in 'less')
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform/examples/production"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${RED}WARNING: This will destroy ALL deployed AWS resources and local files.${NC}"
read -p "Are you sure? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

cd "${TERRAFORM_DIR}"

###############################################################################
# Empty all S3 buckets in Terraform state (handles versioned buckets)
###############################################################################

empty_s3_bucket() {
    local BUCKET="$1"
    if [ -z "${BUCKET}" ]; then return; fi

    log_info "Emptying S3 bucket: ${BUCKET}"

    # Delete all current objects (handles pagination automatically)
    aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true

    # Delete all versioned objects and delete markers in batches
    while true; do
        VERSIONS=$(aws s3api list-object-versions --bucket "${BUCKET}" \
            --max-items 500 \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects": null}')

        OBJECTS=$(echo "${VERSIONS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d))" 2>/dev/null || echo '{"Objects": null}')

        if echo "${OBJECTS}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('Objects') else 1)" 2>/dev/null; then
            aws s3api delete-objects --bucket "${BUCKET}" --delete "${OBJECTS}" >/dev/null 2>&1 || true
        else
            break
        fi
    done

    # Delete all delete markers
    while true; do
        MARKERS=$(aws s3api list-object-versions --bucket "${BUCKET}" \
            --max-items 500 \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects": null}')

        if echo "${MARKERS}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('Objects') else 1)" 2>/dev/null; then
            aws s3api delete-objects --bucket "${BUCKET}" --delete "${MARKERS}" >/dev/null 2>&1 || true
        else
            break
        fi
    done

    log_info "Bucket ${BUCKET} emptied."
}

# Get all S3 buckets from Terraform state (not just outputs)
log_info "Finding all S3 buckets in Terraform state..."
ALL_BUCKETS=$(terraform state list 2>/dev/null | grep "aws_s3_bucket\." | grep -v "versioning\|encryption\|public_access\|policy\|object" || true)

for RESOURCE in ${ALL_BUCKETS}; do
    BUCKET=$(terraform state show "${RESOURCE}" 2>/dev/null | grep '^\s*bucket\s*=' | head -1 | awk -F'"' '{print $2}' || true)
    if [ -n "${BUCKET}" ]; then
        empty_s3_bucket "${BUCKET}"
    fi
done

###############################################################################
# Delete ECR images (UI and agent repos)
###############################################################################

for ECR_OUTPUT in ecr_ui_repository_url ecr_agent_repository_url; do
    ECR_REPO=$(terraform output -raw "${ECR_OUTPUT}" 2>/dev/null || echo "")
    if [ -n "${ECR_REPO}" ]; then
        REPO_NAME=$(echo "${ECR_REPO}" | cut -d'/' -f2)
        log_info "Deleting ECR images: ${REPO_NAME}"
        IMAGES=$(aws ecr list-images --repository-name "${REPO_NAME}" \
            --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
        if [ "${IMAGES}" != "[]" ] && [ -n "${IMAGES}" ]; then
            aws ecr batch-delete-image \
                --repository-name "${REPO_NAME}" \
                --image-ids "${IMAGES}" 2>/dev/null || true
        fi
    fi
done

###############################################################################
# Disable ALB deletion protection before destroy
###############################################################################

log_info "Disabling ALB deletion protection..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "${PROJECT_NAME:-eks-migration-agent}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "")
if [ -n "${ALB_ARN}" ] && [ "${ALB_ARN}" != "None" ]; then
    aws elbv2 modify-load-balancer-attributes \
        --load-balancer-arn "${ALB_ARN}" \
        --attributes Key=deletion_protection.enabled,Value=false \
        2>/dev/null || true
    log_info "ALB deletion protection disabled."
fi

###############################################################################
# Terraform init + destroy
###############################################################################

log_info "Initializing Terraform..."
terraform init -upgrade -input=false

log_info "Running terraform destroy..."
terraform destroy -auto-approve

cd "${PROJECT_ROOT}"

###############################################################################
# Remove local build artifacts and Terraform state files (always runs)
###############################################################################

set +e  # Don't exit on errors during cleanup

log_info "Cleaning local build artifacts..."
rm -rf dist/
rm -f "${PROJECT_ROOT}/src/agent-source.zip"
rm -f "${PROJECT_ROOT}/src/ui-source.zip"

log_info "Cleaning Terraform local files..."
rm -f  "${TERRAFORM_DIR}/tfplan"
rm -rf "${TERRAFORM_DIR}/.terraform"
rm -f  "${TERRAFORM_DIR}/.terraform.lock.hcl"
rm -f  "${TERRAFORM_DIR}/terraform.tfstate"
rm -f  "${TERRAFORM_DIR}/terraform.tfstate.backup"
rm -f  "${TERRAFORM_DIR}/.terraform.tfstate.lock.info"

log_info "Cleanup complete. All resources destroyed and local files removed."
