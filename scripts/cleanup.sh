#!/bin/bash
###############################################################################
# Cleanup Script
# - Empties all S3 buckets (including versioned objects)
# - Deletes all ECR images
# - Runs terraform destroy
# - Sweeps resources that terraform destroy left behind (orphans)
# - Removes local state/build files ONLY if nothing was left behind
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
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

###############################################################################
# Resolve project_name / aws_region from tfvars (same convention as deploy.sh)
###############################################################################

read_tfvar() {
    grep -E "^\s*$1\s*=" "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null \
        | sed 's/.*= *"\([^"]*\)".*/\1/' | head -1 || echo ""
}

PROJECT_NAME="$(read_tfvar project_name)"
PROJECT_NAME="${PROJECT_NAME:-eks-migration-agent}"
AWS_REGION_VAL="$(read_tfvar aws_region)"
AWS_REGION_VAL="${AWS_REGION_VAL:-${AWS_REGION:-us-east-1}}"

# Project tag set via provider default_tags — used to scope the orphan sweep so
# we never touch keys/resources that belong to something else in this account.
PROJECT_TAG="eks-migration-assessment-agent"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
fi
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo -e "${RED}WARNING: This will destroy ALL deployed AWS resources and local files.${NC}"
echo "  Account : ${ACCOUNT_ID}"
echo "  Region  : ${AWS_REGION_VAL}"
echo "  Project : ${PROJECT_NAME}"
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
    if ! aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then return; fi

    log_info "Emptying S3 bucket: ${BUCKET}"

    # Delete all current objects (handles pagination automatically)
    aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true

    # Delete versioned objects and delete markers in batches. The guard counter
    # prevents an infinite loop if a batch delete keeps failing (e.g. an object
    # lock) and the same versions come back on every list call.
    local KEY GUARD
    for KEY in Versions DeleteMarkers; do
        GUARD=0
        while [ "${GUARD}" -lt 100 ]; do
            GUARD=$((GUARD + 1))
            local BATCH
            BATCH=$(aws s3api list-object-versions --bucket "${BUCKET}" \
                --max-items 500 \
                --query "{Objects: ${KEY}[].{Key:Key,VersionId:VersionId}}" \
                --output json 2>/dev/null || echo '{"Objects": null}')

            if ! echo "${BATCH}" | python3 -c \
                "import sys,json; sys.exit(0 if json.load(sys.stdin).get('Objects') else 1)" 2>/dev/null; then
                break
            fi

            if ! aws s3api delete-objects --bucket "${BUCKET}" \
                --delete "${BATCH}" >/dev/null 2>&1; then
                log_warn "Could not delete a batch of ${KEY} in ${BUCKET}; stopping."
                break
            fi
        done
        if [ "${GUARD}" -ge 100 ]; then
            log_warn "Hit batch limit emptying ${KEY} in ${BUCKET}; may not be fully empty."
        fi
    done

    log_info "Bucket ${BUCKET} emptied."
}

HAVE_STATE=false
if [ -f "${TERRAFORM_DIR}/terraform.tfstate" ] || [ -d "${TERRAFORM_DIR}/.terraform" ]; then
    HAVE_STATE=true
fi

if [ "${HAVE_STATE}" = true ]; then
    log_info "Finding all S3 buckets in Terraform state..."
    ALL_BUCKETS=$(terraform state list 2>/dev/null \
        | grep "aws_s3_bucket\." \
        | grep -v "versioning\|encryption\|public_access\|policy\|object" || true)

    for RESOURCE in ${ALL_BUCKETS}; do
        BUCKET=$(terraform state show "${RESOURCE}" 2>/dev/null \
            | grep '^\s*bucket\s*=' | head -1 | awk -F'"' '{print $2}' || true)
        [ -n "${BUCKET}" ] && empty_s3_bucket "${BUCKET}"
    done
else
    log_warn "No Terraform state found — skipping state-based cleanup."
    log_warn "The orphan sweep below will find and remove leftover resources."
fi

###############################################################################
# Delete ECR images — by prefix, so it still works without state/outputs
###############################################################################

ECR_REPOS=$(aws ecr describe-repositories --region "${AWS_REGION_VAL}" \
    --query "repositories[?starts_with(repositoryName,'${PROJECT_NAME}')].repositoryName" \
    --output text 2>/dev/null || true)

for REPO_NAME in ${ECR_REPOS}; do
    log_info "Deleting ECR images: ${REPO_NAME}"
    IMAGES=$(aws ecr list-images --repository-name "${REPO_NAME}" \
        --region "${AWS_REGION_VAL}" \
        --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
    if [ "${IMAGES}" != "[]" ] && [ -n "${IMAGES}" ]; then
        aws ecr batch-delete-image \
            --repository-name "${REPO_NAME}" \
            --image-ids "${IMAGES}" \
            --region "${AWS_REGION_VAL}" >/dev/null 2>&1 || true
    fi
done

###############################################################################
# Disable ALB deletion protection before destroy
###############################################################################

log_info "Disabling ALB deletion protection..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "${PROJECT_NAME}-alb" \
    --region "${AWS_REGION_VAL}" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "")
if [ -n "${ALB_ARN}" ] && [ "${ALB_ARN}" != "None" ]; then
    aws elbv2 modify-load-balancer-attributes \
        --load-balancer-arn "${ALB_ARN}" \
        --attributes Key=deletion_protection.enabled,Value=false \
        --region "${AWS_REGION_VAL}" >/dev/null 2>&1 || true
    log_info "ALB deletion protection disabled."
fi

###############################################################################
# Terraform init + destroy
#
# Not fatal if destroy fails — we still want the orphan sweep to run and report.
# DESTROY_OK gates whether local state may be deleted at the end.
###############################################################################

DESTROY_OK=true

if [ "${HAVE_STATE}" = true ]; then
    log_info "Initializing Terraform..."
    if ! terraform init -upgrade -input=false; then
        log_error "terraform init failed."
        DESTROY_OK=false
    fi

    if [ "${DESTROY_OK}" = true ]; then
        log_info "Running terraform destroy..."
        if ! terraform destroy -auto-approve; then
            log_warn "terraform destroy reported errors — retrying once."
            if ! terraform destroy -auto-approve; then
                log_error "terraform destroy failed. State will be KEPT so you can retry."
                DESTROY_OK=false
            fi
        fi
    fi

    # `grep -v` exits 1 when state is empty, which pipefail would turn into a
    # script-killing error — hence the `|| true`.
    REMAINING=$(terraform state list 2>/dev/null | grep -vc '^data\.' || true)
    REMAINING="${REMAINING:-0}"
    if [ "${REMAINING}" != "0" ]; then
        log_warn "${REMAINING} resource(s) still in state after destroy."
        DESTROY_OK=false
    fi
fi

###############################################################################
# Orphan sweep — resources destroy could not see
#
# Scoped by project name prefix and the Project tag. Anything without that tag
# is left alone, so unrelated resources in this account are never touched.
###############################################################################

log_info "Scanning for orphaned resources (not tracked by Terraform)..."

ORPHAN_KMS=""       # "keyid alias" pairs
ORPHAN_BUCKETS=""
ORPHAN_TABLES=""
ORPHAN_REPOS=""
ORPHAN_LOGS=""

# --- KMS: only CUSTOMER-managed keys carrying our Project tag, not already
# --- pending deletion. The alias is what blocks the next apply.
for KEY_ID in $(aws kms list-keys --region "${AWS_REGION_VAL}" \
                    --query 'Keys[].KeyId' --output text 2>/dev/null || true); do
    META=$(aws kms describe-key --key-id "${KEY_ID}" --region "${AWS_REGION_VAL}" \
        --query 'KeyMetadata.{Mgr:KeyManager,State:KeyState}' --output json 2>/dev/null || echo '{}')
    MGR=$(echo "${META}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('Mgr',''))" 2>/dev/null || echo "")
    STATE=$(echo "${META}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('State',''))" 2>/dev/null || echo "")
    [ "${MGR}" != "CUSTOMER" ] && continue
    [ "${STATE}" = "PendingDeletion" ] && continue

    TAG=$(aws kms list-resource-tags --key-id "${KEY_ID}" --region "${AWS_REGION_VAL}" \
        --query "Tags[?TagKey=='Project'].TagValue" --output text 2>/dev/null || echo "")
    [ "${TAG}" != "${PROJECT_TAG}" ] && continue

    ALIASES=$(aws kms list-aliases --key-id "${KEY_ID}" --region "${AWS_REGION_VAL}" \
        --query 'Aliases[].AliasName' --output text 2>/dev/null || echo "")
    ORPHAN_KMS="${ORPHAN_KMS}${KEY_ID}|${ALIASES}"$'\n'
done

# A leftover alias can also point at an already-deleted key — catch it directly.
STRAY_ALIAS=$(aws kms list-aliases --region "${AWS_REGION_VAL}" \
    --query "Aliases[?AliasName=='alias/${PROJECT_NAME}'].AliasName" \
    --output text 2>/dev/null || echo "")

# --- S3
for B in $(aws s3api list-buckets \
              --query "Buckets[?starts_with(Name,'${PROJECT_NAME}')].Name" \
              --output text 2>/dev/null || true); do
    ORPHAN_BUCKETS="${ORPHAN_BUCKETS}${B} "
done

# --- DynamoDB
for T in $(aws dynamodb list-tables --region "${AWS_REGION_VAL}" \
              --query "TableNames[?starts_with(@,'${PROJECT_NAME}')]" \
              --output text 2>/dev/null || true); do
    ORPHAN_TABLES="${ORPHAN_TABLES}${T} "
done

# --- ECR
for R in $(aws ecr describe-repositories --region "${AWS_REGION_VAL}" \
              --query "repositories[?starts_with(repositoryName,'${PROJECT_NAME}')].repositoryName" \
              --output text 2>/dev/null || true); do
    ORPHAN_REPOS="${ORPHAN_REPOS}${R} "
done

# --- CloudWatch log groups
for LG in $(aws logs describe-log-groups --region "${AWS_REGION_VAL}" \
               --query "logGroups[?contains(logGroupName,'${PROJECT_NAME}')].logGroupName" \
               --output text 2>/dev/null || true); do
    ORPHAN_LOGS="${ORPHAN_LOGS}${LG} "
done

HAS_ORPHANS=false
if [ -n "$(echo "${ORPHAN_KMS}" | tr -d '\n ')" ] || [ -n "${STRAY_ALIAS}" ] \
   || [ -n "${ORPHAN_BUCKETS}" ] || [ -n "${ORPHAN_TABLES}" ] \
   || [ -n "${ORPHAN_REPOS}" ] || [ -n "${ORPHAN_LOGS}" ]; then
    HAS_ORPHANS=true
fi

if [ "${HAS_ORPHANS}" = true ]; then
    echo
    echo -e "${YELLOW}Orphaned resources found (left over from runs whose state was lost):${NC}"
    echo "${ORPHAN_KMS}" | grep -v '^$' | while IFS='|' read -r k a; do
        echo "  KMS key      ${k}  alias=${a:-none}"
    done || true
    [ -n "${STRAY_ALIAS}" ]    && echo "  KMS alias    ${STRAY_ALIAS}"    || true
    [ -n "${ORPHAN_BUCKETS}" ] && echo "  S3 buckets   ${ORPHAN_BUCKETS}" || true
    [ -n "${ORPHAN_TABLES}" ]  && echo "  DynamoDB     ${ORPHAN_TABLES}"  || true
    [ -n "${ORPHAN_REPOS}" ]   && echo "  ECR repos    ${ORPHAN_REPOS}"   || true
    [ -n "${ORPHAN_LOGS}" ]    && echo "  Log groups   ${ORPHAN_LOGS}"    || true
    echo
    echo -e "${RED}KMS keys are scheduled for deletion with a 30-day window and keep${NC}"
    echo -e "${RED}billing until then. Buckets and tables are deleted immediately.${NC}"
    read -p "Delete these orphaned resources? (yes/no): " sweep_confirm

    if [ "${sweep_confirm}" = "yes" ]; then
        SWEEP_OK=true

        # Order matters: delete the KMS-encrypted resources FIRST, then the keys.
        # Emptying a bucket encrypted with a disabled/pending key can fail.
        for B in ${ORPHAN_BUCKETS}; do
            empty_s3_bucket "${B}"
            log_info "Deleting S3 bucket: ${B}"
            aws s3api delete-bucket --bucket "${B}" \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                || { log_warn "Could not delete bucket ${B}"; SWEEP_OK=false; }
        done

        for T in ${ORPHAN_TABLES}; do
            log_info "Deleting DynamoDB table: ${T}"
            aws dynamodb delete-table --table-name "${T}" \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                || { log_warn "Could not delete table ${T}"; SWEEP_OK=false; }
        done

        for R in ${ORPHAN_REPOS}; do
            log_info "Deleting ECR repository: ${R}"
            aws ecr delete-repository --repository-name "${R}" --force \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                || { log_warn "Could not delete repo ${R}"; SWEEP_OK=false; }
        done

        for LG in ${ORPHAN_LOGS}; do
            log_info "Deleting log group: ${LG}"
            aws logs delete-log-group --log-group-name "${LG}" \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                || { log_warn "Could not delete log group ${LG}"; SWEEP_OK=false; }
        done

        # KMS last. Looping over a here-string (not a pipe) keeps this in the
        # current shell, so SWEEP_OK assignments actually stick.
        while IFS='|' read -r KEY_ID ALIASES; do
            [ -z "${KEY_ID}" ] && continue
            for A in ${ALIASES}; do
                log_info "Deleting KMS alias: ${A}"
                aws kms delete-alias --alias-name "${A}" \
                    --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                    || { log_warn "Could not delete alias ${A}"; SWEEP_OK=false; }
            done
            log_info "Scheduling KMS key deletion (30d): ${KEY_ID}"
            aws kms schedule-key-deletion --key-id "${KEY_ID}" \
                --pending-window-in-days 30 \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 \
                || { log_warn "Could not schedule deletion for ${KEY_ID}"; SWEEP_OK=false; }
        done <<< "${ORPHAN_KMS}"

        if [ -n "${STRAY_ALIAS}" ]; then
            log_info "Deleting stray KMS alias: ${STRAY_ALIAS}"
            aws kms delete-alias --alias-name "${STRAY_ALIAS}" \
                --region "${AWS_REGION_VAL}" >/dev/null 2>&1 || true
        fi

        if [ "${SWEEP_OK}" = true ]; then
            log_info "Orphan sweep complete."
        else
            log_warn "Orphan sweep finished with errors — re-run to retry."
            DESTROY_OK=false
        fi
    else
        log_warn "Orphan sweep skipped. The next 'terraform apply' will likely fail"
        log_warn "with AlreadyExistsException on alias/${PROJECT_NAME}."
        DESTROY_OK=false
    fi
fi

cd "${PROJECT_ROOT}"

###############################################################################
# Remove local build artifacts
###############################################################################

set +e  # Don't exit on errors during cleanup

log_info "Cleaning local build artifacts..."
rm -rf "${PROJECT_ROOT}/dist/"
rm -f  "${PROJECT_ROOT}/src/agent-source.zip"
rm -f  "${PROJECT_ROOT}/src/ui-source.zip"

log_info "Cleaning Python cache files..."
find "${PROJECT_ROOT}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
find "${PROJECT_ROOT}" -name "*.pyc" -delete 2>/dev/null
find "${PROJECT_ROOT}" -name "*.pyo" -delete 2>/dev/null

log_info "Cleaning misc generated files..."
find "${PROJECT_ROOT}" -name ".DS_Store" -delete 2>/dev/null

###############################################################################
# Remove Terraform state — ONLY when nothing was left behind.
#
# Deleting state while resources are still live is what orphans them and makes
# the next apply collide on account-unique names.
###############################################################################

if [ "${DESTROY_OK}" != true ]; then
    echo
    log_warn "Keeping Terraform state: destroy did not complete cleanly."
    log_warn "State file: ${TERRAFORM_DIR}/terraform.tfstate"
    log_warn "Fix the errors above and re-run this script. Do not delete state"
    log_warn "manually — it is the only record of what still exists in AWS."
    exit 1
fi

log_info "Cleaning Terraform local files..."
rm -f  "${TERRAFORM_DIR}/tfplan"
rm -rf "${TERRAFORM_DIR}/.terraform"
rm -f  "${TERRAFORM_DIR}/.terraform.lock.hcl"
rm -f  "${TERRAFORM_DIR}/terraform.tfstate"
rm -f  "${TERRAFORM_DIR}/terraform.tfstate.backup"
rm -f  "${TERRAFORM_DIR}/.terraform.tfstate.lock.info"

find "${PROJECT_ROOT}/terraform" -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null
find "${PROJECT_ROOT}/terraform" -name ".terraform.lock.hcl" -delete 2>/dev/null
find "${PROJECT_ROOT}/terraform" -name "terraform.tfstate" -delete 2>/dev/null
find "${PROJECT_ROOT}/terraform" -name "terraform.tfstate.backup" -delete 2>/dev/null
find "${PROJECT_ROOT}/terraform" -name ".terraform.tfstate.lock.info" -delete 2>/dev/null
find "${PROJECT_ROOT}/terraform" -name "tfplan" -delete 2>/dev/null

log_info "Cleanup complete. All resources destroyed and local files removed."
