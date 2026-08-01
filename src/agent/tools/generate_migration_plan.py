"""
Tool: generate_migration_plan
Produces scored readiness report with effort estimates and migration runbook.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from strands import tool

logger = logging.getLogger(__name__)

dynamodb = boto3.resource("dynamodb")
DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "")


@tool
def generate_migration_plan(
    app_name: str,
    source_analysis: dict,
    dependency_scan: dict,
    eks_compatibility: dict,
) -> dict[str, Any]:
    """Generate a comprehensive EKS migration plan with readiness scoring.

    Aggregates findings from all analysis tools and produces a final scored
    readiness report with effort estimates, prioritized remediation steps,
    and recommended target EKS architecture.

    Args:
        app_name: Name of the application being assessed.
        source_analysis: Results from analyze_source_code tool.
        dependency_scan: Results from scan_dependencies tool.
        eks_compatibility: Results from check_eks_compatibility tool.

    Returns:
        Dictionary containing readiness score, findings, effort estimates,
        migration runbook, and target architecture recommendation.
    """
    logger.info("Generating migration plan for: %s", app_name)

    # Aggregate all findings
    all_findings = _aggregate_findings(source_analysis, dependency_scan, eks_compatibility)

    # Calculate overall readiness score
    readiness_score = _calculate_overall_score(all_findings)

    # Generate effort breakdown
    effort_breakdown = _estimate_effort(all_findings)

    # Build migration runbook
    runbook = _generate_runbook(all_findings, app_name)

    # Recommend target architecture
    target_architecture = _recommend_eks_architecture(
        dependency_scan.get("stateful_components", []),
        eks_compatibility.get("networking", []),
    )

    # Determine readiness category
    if readiness_score >= 80:
        readiness_category = "READY — minimal changes needed (1-3 days)"
    elif readiness_score >= 60:
        readiness_category = "READY WITH EFFORT — moderate refactoring (5-10 days)"
    elif readiness_score >= 40:
        readiness_category = "CONDITIONALLY READY — significant work required (10-20 days)"
    elif readiness_score >= 20:
        readiness_category = "MAJOR REWORK — substantial refactoring needed (20-40 days)"
    else:
        readiness_category = "RE-ARCHITECTURE REQUIRED — fundamental design changes (40+ days)"

    result = {
        "assessment_id": str(uuid.uuid4()),
        "app_name": app_name,
        "assessed_at": datetime.now(timezone.utc).isoformat(),
        "readiness_score": readiness_score,
        "readiness_category": readiness_category,
        "findings": all_findings,
        "effort_estimate": effort_breakdown,
        "migration_runbook": runbook,
        "target_architecture": target_architecture,
    }

    # Persist to DynamoDB
    _persist_assessment(result)

    logger.info(
        "Migration plan generated for %s: score=%d, category=%s",
        app_name,
        readiness_score,
        readiness_category,
    )

    return result


def _aggregate_findings(
    source_analysis: dict,
    dependency_scan: dict,
    eks_compatibility: dict,
) -> list[dict]:
    """Aggregate and deduplicate findings from all tools."""
    findings = []

    # Source code findings
    for item in source_analysis.get("blockers", []):
        item["source"] = "source_code_analysis"
        findings.append(item)
    for item in source_analysis.get("warnings", []):
        item["source"] = "source_code_analysis"
        findings.append(item)
    for item in source_analysis.get("info", []):
        item["source"] = "source_code_analysis"
        findings.append(item)

    # Dependency findings
    for item in dependency_scan.get("compatibility_issues", []):
        item["source"] = "dependency_scan"
        findings.append(item)
    for component in dependency_scan.get("stateful_components", []):
        findings.append({
            "type": "stateful_component",
            "severity": "MEDIUM",
            "details": f"Stateful service: {component['service']} ({component['type']})",
            "recommendation": component.get("recommendation", ""),
            "source": "dependency_scan",
            "effort_hours": 4,
        })

    # EKS compatibility findings
    for category in ("dockerfile", "compose", "networking", "security"):
        for item in eks_compatibility.get(category, []):
            item["source"] = "eks_compatibility"
            findings.append(item)

    # Sort by severity
    severity_order = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
    findings.sort(key=lambda f: severity_order.get(f.get("severity", "LOW"), 3))

    return findings


def _calculate_overall_score(findings: list[dict]) -> int:
    """Calculate weighted readiness score based on unique issue types."""
    # Deduplicate by type — same issue in multiple files counts once
    high_types = set()
    medium_types = set()
    low_types = set()

    for finding in findings:
        ftype = finding.get("type", "unknown")
        severity = finding.get("severity", "LOW")
        if severity == "HIGH":
            high_types.add(ftype)
        elif severity == "MEDIUM":
            medium_types.add(ftype)
        else:
            low_types.add(ftype)

    score = 100
    score -= len(high_types) * 10  # Each unique HIGH blocker type: -10
    score -= len(medium_types) * 5  # Each unique MEDIUM type: -5
    score -= len(low_types) * 2     # Each unique LOW type: -2

    return max(5, min(100, score))  # Minimum 5 — every app CAN be migrated


def _estimate_effort(findings: list[dict]) -> dict:
    """Calculate realistic effort estimates based on finding severity and count."""
    # Deduplicate by type — same issue in multiple files is ONE fix
    unique_types = {}
    for finding in findings:
        ftype = finding.get("type", "unknown")
        severity = finding.get("severity", "LOW")
        # Keep highest severity if same type appears with different severities
        if ftype not in unique_types or severity == "HIGH":
            unique_types[ftype] = severity

    # Effort per severity (hours per unique issue type)
    severity_effort = {"HIGH": 6, "MEDIUM": 3, "LOW": 1}

    total_hours = sum(severity_effort.get(sev, 2) for sev in unique_types.values())

    # Scale factor: more unique issues = some overlap in fixing (not linear)
    # First 5 issues: full effort. Beyond 5: 70% effort (shared refactoring)
    issue_count = len(unique_types)
    if issue_count > 5:
        overlap_savings = (issue_count - 5) * 0.3 * severity_effort["MEDIUM"]
        total_hours = max(total_hours - overlap_savings, issue_count * 2)

    total_hours = round(total_hours)

    # EKS setup (manifests, CI/CD, monitoring, testing) — scales slightly with complexity
    eks_setup_hours = 16 + (4 if issue_count > 10 else 0)

    total = total_hours + eks_setup_hours

    return {
        "remediation_hours": total_hours,
        "eks_setup_hours": eks_setup_hours,
        "total_hours": total,
        "estimated_days": round(total / 8, 1),
        "unique_issue_types": issue_count,
    }


def _generate_runbook(findings: list[dict], app_name: str) -> list[dict]:
    """Generate step-by-step migration runbook."""
    runbook = []
    step = 1

    # Phase 1: Remediate blockers
    high_findings = [f for f in findings if f.get("severity") == "HIGH"]
    if high_findings:
        runbook.append({
            "phase": "Phase 1: Remediate Blockers",
            "steps": [
                {
                    "step": step + i,
                    "action": f"Fix: {f.get('type', 'unknown')}",
                    "details": f.get("recommendation", ""),
                    "effort_hours": f.get("effort_hours", 2),
                }
                for i, f in enumerate(high_findings)
            ],
        })
        step += len(high_findings)

    # Phase 2: Containerization
    runbook.append({
        "phase": "Phase 2: Containerization",
        "steps": [
            {"step": step, "action": "Optimize Dockerfile with multi-stage build", "effort_hours": 2},
            {"step": step + 1, "action": "Configure health check endpoints", "effort_hours": 2},
            {"step": step + 2, "action": "Externalize configuration to environment variables", "effort_hours": 2},
            {"step": step + 3, "action": "Build and test container image locally", "effort_hours": 2},
        ],
    })
    step += 4

    # Phase 3: Kubernetes manifests
    runbook.append({
        "phase": "Phase 3: Kubernetes Manifests",
        "steps": [
            {"step": step, "action": "Create Deployment manifest with resource limits", "effort_hours": 2},
            {"step": step + 1, "action": "Create Service and Ingress resources", "effort_hours": 2},
            {"step": step + 2, "action": "Configure ConfigMaps and Secrets", "effort_hours": 2},
            {"step": step + 3, "action": "Set up PersistentVolumeClaims if needed", "effort_hours": 2},
            {"step": step + 4, "action": "Define HorizontalPodAutoscaler", "effort_hours": 1},
        ],
    })
    step += 5

    # Phase 4: Deploy and validate
    runbook.append({
        "phase": "Phase 4: Deploy and Validate",
        "steps": [
            {"step": step, "action": "Deploy to EKS staging environment", "effort_hours": 2},
            {"step": step + 1, "action": "Run integration tests", "effort_hours": 4},
            {"step": step + 2, "action": "Configure monitoring and alerting", "effort_hours": 2},
            {"step": step + 3, "action": "Perform load testing", "effort_hours": 4},
            {"step": step + 4, "action": "Execute production cutover", "effort_hours": 2},
        ],
    })

    return runbook


def _recommend_eks_architecture(
    stateful_components: list[dict],
    networking_findings: list[dict],
) -> dict:
    """Recommend target EKS architecture based on findings."""
    architecture = {
        "compute": {
            "type": "Deployment",
            "replicas": 3,
            "strategy": "RollingUpdate",
            "resources": {
                "requests": {"cpu": "500m", "memory": "512Mi"},
                "limits": {"cpu": "1000m", "memory": "1Gi"},
            },
        },
        "networking": {
            "service_type": "ClusterIP",
            "ingress": "AWS Load Balancer Controller (ALB)",
            "service_mesh": "Optional: AWS App Mesh or Istio",
        },
        "storage": [],
        "managed_services": [],
        "security": {
            "pod_security_standard": "restricted",
            "service_account": "IRSA (IAM Roles for Service Accounts)",
            "secrets_management": "AWS Secrets Manager + External Secrets Operator",  # pragma: allowlist secret
            "network_policy": "Kubernetes NetworkPolicy",
        },
        "observability": {
            "metrics": "Amazon CloudWatch Container Insights",
            "logging": "Fluent Bit to CloudWatch Logs",
            "tracing": "AWS X-Ray",
        },
    }

    # Add storage recommendations based on stateful components
    for component in stateful_components:
        if component.get("type") == "database":
            architecture["managed_services"].append({
                "service": component.get("eks_alternative", "Amazon RDS"),
                "purpose": f"Managed {component.get('service', 'database')}",
            })
        elif component.get("type") in ("cache", "cache/session"):
            architecture["managed_services"].append({
                "service": component.get("eks_alternative", "Amazon ElastiCache"),
                "purpose": f"Managed {component.get('service', 'cache')}",
            })
        elif component.get("type") == "message_queue":
            architecture["managed_services"].append({
                "service": component.get("eks_alternative", "Amazon MQ"),
                "purpose": f"Managed {component.get('service', 'message queue')}",
            })

    return architecture


def _persist_assessment(result: dict) -> None:
    """Store assessment result in DynamoDB."""
    if not DYNAMODB_TABLE:
        logger.warning("DYNAMODB_TABLE not set, skipping persistence")
        return

    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        table.put_item(
            Item={
                "assessment_id": result["assessment_id"],
                "created_at": result["assessed_at"],
                "app_name": result["app_name"],
                "readiness_score": result["readiness_score"],
                "readiness_category": result["readiness_category"],
                "findings_count": len(result["findings"]),
                "total_effort_hours": result["effort_estimate"]["total_hours"],
                "result_json": json.dumps(result, default=str),
            }
        )
        logger.info("Assessment persisted: %s", result["assessment_id"])
    except Exception as e:
        logger.error("Failed to persist assessment: %s", str(e))

    # Cleanup: delete source files from S3 after assessment is persisted
    _cleanup_s3_artifacts(result.get("app_name", ""))


def _cleanup_s3_artifacts(app_name: str) -> None:
    """Delete uploaded source files from S3 after assessment completes."""
    s3_bucket = os.environ.get("S3_BUCKET_NAME", "")
    if not s3_bucket or not app_name:
        return

    try:
        s3 = boto3.client("s3")
        prefix = f"assessments/{app_name}/"
        paginator = s3.get_paginator("list_objects_v2")

        objects_to_delete = []
        for page in paginator.paginate(Bucket=s3_bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                objects_to_delete.append({"Key": obj["Key"]})

        if objects_to_delete:
            # Delete in batches of 1000
            for i in range(0, len(objects_to_delete), 1000):
                batch = objects_to_delete[i:i + 1000]
                s3.delete_objects(Bucket=s3_bucket, Delete={"Objects": batch})
            logger.info("Cleaned up %d files from s3://%s/%s", len(objects_to_delete), s3_bucket, prefix)
    except Exception as e:
        logger.warning("S3 cleanup failed (non-critical): %s", str(e))
