"""
Tool: check_eks_compatibility
Validates container artifacts against Amazon EKS best practices.
"""

import logging
import os
import re
from typing import Any

import boto3
from strands import tool

logger = logging.getLogger(__name__)

s3_client = boto3.client("s3")
S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "")


@tool
def check_eks_compatibility(s3_prefix: str) -> dict[str, Any]:
    """Check application compatibility with Amazon EKS best practices.

    Validates Dockerfiles, Docker Compose files, and related artifacts against
    EKS best practices for networking, storage, security, and resource management.

    Args:
        s3_prefix: The S3 key prefix where container artifacts are stored.

    Returns:
        Dictionary containing findings for Dockerfile, compose, networking, and security.
    """
    logger.info("Checking EKS compatibility at s3://%s/%s", S3_BUCKET, s3_prefix)

    artifacts = _retrieve_container_artifacts(s3_prefix)

    dockerfile_findings = _analyze_dockerfile(artifacts.get("Dockerfile", ""))
    compose_findings = _analyze_compose(artifacts.get("docker-compose.yml", artifacts.get("docker-compose.yaml", "")))
    networking_findings = _assess_networking(artifacts)
    security_findings = _assess_security(artifacts)

    # Calculate readiness score
    all_findings = dockerfile_findings + compose_findings + networking_findings + security_findings
    readiness_score = _calculate_readiness_score(all_findings)

    result = {
        "dockerfile": dockerfile_findings,
        "compose": compose_findings,
        "networking": networking_findings,
        "security": security_findings,
        "eks_readiness_score": readiness_score,
        "summary": {
            "total_findings": len(all_findings),
            "high_severity": sum(1 for f in all_findings if f["severity"] == "HIGH"),
            "medium_severity": sum(1 for f in all_findings if f["severity"] == "MEDIUM"),
            "low_severity": sum(1 for f in all_findings if f["severity"] == "LOW"),
        },
    }

    logger.info("EKS compatibility check complete. Readiness score: %d/100", readiness_score)
    return result


def _retrieve_container_artifacts(s3_prefix: str) -> dict[str, str]:
    """Retrieve container-related files from S3."""
    files = {}
    target_files = {
        "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
        ".dockerignore", "nginx.conf", "supervisord.conf",
        "crontab", "websphere-config.xml",
        "deployment.yaml", "service.yaml", "ingress.yaml",
        "route.yaml", "deploymentconfig.yaml", "values.yaml",
    }

    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=s3_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            filename = os.path.basename(key)
            if filename in target_files or filename.startswith("Dockerfile"):
                try:
                    response = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
                    content = response["Body"].read().decode("utf-8", errors="ignore")
                    files[filename] = content
                except Exception as e:
                    logger.warning("Failed to read %s: %s", key, str(e))

    return files


def _analyze_dockerfile(content: str) -> list[dict]:
    """Analyze Dockerfile against best practices."""
    findings = []

    if not content:
        findings.append({
            "type": "missing_dockerfile",
            "severity": "HIGH",
            "details": "No Dockerfile found. Application needs containerization.",
            "recommendation": "Create a Dockerfile following multi-stage build best practices.",
            "effort_hours": 4,
        })
        return findings

    # Check for multi-stage build
    from_count = len(re.findall(r"^FROM\s+", content, re.MULTILINE))
    if from_count < 2:
        findings.append({
            "type": "single_stage_build",
            "severity": "LOW",
            "details": "Single-stage Dockerfile produces larger images.",
            "recommendation": (
                "Use multi-stage build to separate build and runtime stages. "
                "This reduces image size and attack surface."
            ),
            "effort_hours": 1,
        })

    # Check for non-root user
    if not re.search(r"^USER\s+(?!root)", content, re.MULTILINE):
        findings.append({
            "type": "root_user",
            "severity": "HIGH",
            "details": "Container runs as root user. EKS Pod Security Standards require non-root.",
            "recommendation": (
                "Add a non-root USER instruction. EKS Pod Security Standards (restricted) "
                "require containers to run as non-root."
            ),
            "effort_hours": 1,
        })

    # Check for HEALTHCHECK
    if "HEALTHCHECK" not in content:
        findings.append({
            "type": "missing_healthcheck",
            "severity": "MEDIUM",
            "details": "No HEALTHCHECK defined. Kubernetes needs liveness/readiness probes.",
            "recommendation": (
                "Add HEALTHCHECK instruction or define Kubernetes liveness and readiness "
                "probes in the pod spec. Probes enable automatic restart of unhealthy pods."
            ),
            "effort_hours": 2,
        })

    # Check for pinned base image
    from_lines = re.findall(r"^FROM\s+(.+?)(?:\s+AS\s+\w+)?$", content, re.MULTILINE)
    for from_line in from_lines:
        if ":latest" in from_line or ":" not in from_line.split("@")[0]:
            findings.append({
                "type": "unpinned_base_image",
                "severity": "MEDIUM",
                "details": f"Base image not pinned: {from_line}. Builds may be non-reproducible.",
                "recommendation": "Pin base image to specific version or SHA digest for reproducible builds.",
                "effort_hours": 0.5,
            })
            break

    # Check for COPY vs ADD
    if re.search(r"^ADD\s+(?!https?://)", content, re.MULTILINE):
        findings.append({
            "type": "use_of_add",
            "severity": "LOW",
            "details": "Using ADD instead of COPY. ADD has implicit tar extraction behavior.",
            "recommendation": "Use COPY instead of ADD unless you specifically need tar auto-extraction.",
            "effort_hours": 0.5,
        })

    return findings


def _analyze_compose(content: str) -> list[dict]:
    """Analyze Docker Compose file for EKS migration considerations."""
    findings = []

    if not content:
        return findings

    # Check for volume mounts (local paths)
    local_volumes = re.findall(r"volumes:\s*\n(?:\s+-\s*[./].*\n?)+", content)
    if local_volumes:
        findings.append({
            "type": "local_volume_mounts",
            "severity": "HIGH",
            "details": "Local path volume mounts detected. These won't work on EKS.",
            "recommendation": (
                "Replace local volume mounts with PersistentVolumeClaims using "
                "Amazon EBS CSI driver (single-pod) or Amazon EFS CSI driver (shared)."
            ),
            "effort_hours": 4,
        })

    # Check for host networking
    if "network_mode: host" in content or "network_mode: \"host\"" in content:
        findings.append({
            "type": "host_networking",
            "severity": "HIGH",
            "details": "Host networking mode detected. Not compatible with EKS pod networking.",
            "recommendation": "Use Kubernetes Service and Ingress resources for networking.",
            "effort_hours": 4,
        })

    # Check for privileged mode
    if "privileged: true" in content:
        findings.append({
            "type": "privileged_mode",
            "severity": "HIGH",
            "details": "Privileged container detected. Blocked by EKS Pod Security Standards.",
            "recommendation": (
                "Remove privileged mode. Use specific Linux capabilities if needed. "
                "EKS restricted Pod Security Standard blocks privileged containers."
            ),
            "effort_hours": 4,
        })

    # Check for depends_on (service dependencies)
    depends_on_count = content.count("depends_on:")
    if depends_on_count > 0:
        findings.append({
            "type": "service_dependencies",
            "severity": "LOW",
            "details": f"Found {depends_on_count} service dependencies. Need Kubernetes equivalent.",
            "recommendation": (
                "Use init containers or readiness probes to handle startup ordering in EKS. "
                "Consider using Kubernetes Service DNS for service discovery."
            ),
            "effort_hours": 2,
        })

    return findings


def _assess_networking(artifacts: dict) -> list[dict]:
    """Assess networking patterns for EKS compatibility."""
    findings = []
    all_content = "\n".join(artifacts.values())

    # Check for hardcoded ports outside standard ranges
    exposed_ports = re.findall(r"(?:EXPOSE|ports:.*?)\s*(\d+)", all_content)
    privileged_ports = [p for p in exposed_ports if int(p) < 1024 and int(p) != 80 and int(p) != 443]
    if privileged_ports:
        findings.append({
            "type": "privileged_ports",
            "severity": "MEDIUM",
            "details": f"Privileged ports detected: {privileged_ports}. Non-root containers cannot bind to ports < 1024.",
            "recommendation": "Remap to non-privileged ports (>1024) and use Kubernetes Service to expose on standard ports.",
            "effort_hours": 2,
        })

    return findings


def _assess_security(artifacts: dict) -> list[dict]:
    """Assess security posture for EKS deployment."""
    findings = []
    all_content = "\n".join(artifacts.values())

    # Check for secrets in Dockerfile/compose
    secret_patterns = [
        (r"(?:PASSWORD|SECRET|API_KEY|TOKEN)\s*=\s*['\"][^'\"]+['\"]", "Hardcoded secret in file"),
        (r"ENV\s+(?:PASSWORD|SECRET|API_KEY|TOKEN)\s+\S+", "Secret in Dockerfile ENV"),
    ]
    for pattern, desc in secret_patterns:
        if re.search(pattern, all_content, re.IGNORECASE):
            findings.append({
                "type": "exposed_secrets",
                "severity": "HIGH",
                "details": f"{desc} detected. Secrets must not be baked into images.",
                "recommendation": (
                    "Use Kubernetes Secrets or AWS Secrets Manager with External Secrets Operator. "
                    "Never store secrets in container images or environment variables in Dockerfiles."
                ),
                "effort_hours": 3,
            })
            break

    # Check for resource sizing indicators
    mem_patterns = re.findall(r"-Xmx(\d+[gGmM])", all_content)
    cpu_patterns = re.findall(r"cpus:\s*(\d+\.?\d*)", all_content)
    mem_limit_patterns = re.findall(r"mem_limit:\s*(\d+[gGmM])", all_content)
    if mem_patterns or cpu_patterns or mem_limit_patterns:
        findings.append({
            "type": "resource_sizing",
            "severity": "LOW",
            "details": f"Resource indicators found - JVM heap: {mem_patterns}, CPU: {cpu_patterns}, Memory limit: {mem_limit_patterns}",
            "recommendation": (
                "Set Kubernetes resource requests and limits based on current usage. "
                "JVM heap should be 60-75% of container memory limit. "
                "Configure HPA (Horizontal Pod Autoscaler) for dynamic scaling. "
                "Consider using VPA for initial right-sizing."
            ),
            "effort_hours": 2,
        })

    # Check for SSL/TLS certificate dependencies
    cert_patterns = re.findall(
        r"truststore|keystore|ssl\.cert|certs/|\.p12|\.jks|\.pem",
        all_content, re.IGNORECASE
    )
    if cert_patterns:
        findings.append({
            "type": "certificate_management",
            "severity": "MEDIUM",
            "details": f"SSL/TLS certificate dependencies: {list(set(cert_patterns))[:5]}",
            "recommendation": (
                "Use AWS Certificate Manager (ACM) for public certificates. "
                "For internal/mTLS, use cert-manager with Private CA in EKS. "
                "Mount certificates via Kubernetes Secrets, not filesystem paths."
            ),
            "effort_hours": 4,
        })

    return findings


def _calculate_readiness_score(findings: list[dict]) -> int:
    """Calculate overall EKS readiness score (0-100)."""
    score = 100
    for finding in findings:
        severity = finding.get("severity", "LOW")
        if severity == "HIGH":
            score -= 15
        elif severity == "MEDIUM":
            score -= 8
        elif severity == "LOW":
            score -= 3

    return max(0, min(100, score))
