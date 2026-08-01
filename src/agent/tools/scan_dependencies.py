"""
Tool: scan_dependencies
Identifies stateful components, database connections, and library compatibility.
"""

import json
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
def scan_dependencies(s3_prefix: str) -> dict[str, Any]:
    """Scan application dependencies for EKS compatibility issues.

    Analyzes dependency manifests (pom.xml, package.json, requirements.txt, etc.)
    to identify stateful components, database connections, message queues,
    and third-party libraries that may have compatibility issues in containers.

    Args:
        s3_prefix: The S3 key prefix where application artifacts are stored.

    Returns:
        Dictionary containing dependencies, stateful components, and compatibility issues.
    """
    logger.info("Scanning dependencies at s3://%s/%s", S3_BUCKET, s3_prefix)

    artifacts = _retrieve_dependency_files(s3_prefix)
    dependencies = []
    stateful_components = []
    compatibility_issues = []

    # Parse each dependency file type
    for file_path, content in artifacts.items():
        if file_path.endswith("pom.xml"):
            deps = _parse_maven_dependencies(content)
            dependencies.extend(deps)
        elif file_path.endswith("package.json"):
            deps = _parse_npm_dependencies(content)
            dependencies.extend(deps)
        elif file_path.endswith("requirements.txt"):
            deps = _parse_pip_dependencies(content)
            dependencies.extend(deps)
        elif file_path.endswith("build.gradle") or file_path.endswith("build.gradle.kts"):
            deps = _parse_gradle_dependencies(content)
            dependencies.extend(deps)

    # Identify stateful components
    stateful_indicators = {
        "redis": {"type": "cache/session", "service": "Redis", "eks_alternative": "Amazon ElastiCache for Redis"},
        "memcached": {"type": "cache", "service": "Memcached", "eks_alternative": "Amazon ElastiCache for Memcached"},
        "postgresql": {"type": "database", "service": "PostgreSQL", "eks_alternative": "Amazon RDS for PostgreSQL"},
        "mysql": {"type": "database", "service": "MySQL", "eks_alternative": "Amazon RDS for MySQL"},
        "mongodb": {"type": "database", "service": "MongoDB", "eks_alternative": "Amazon DocumentDB"},
        "elasticsearch": {"type": "search", "service": "Elasticsearch", "eks_alternative": "Amazon OpenSearch Service"},
        "rabbitmq": {"type": "message_queue", "service": "RabbitMQ", "eks_alternative": "Amazon MQ for RabbitMQ"},
        "kafka": {"type": "message_queue", "service": "Kafka", "eks_alternative": "Amazon MSK"},
        "activemq": {"type": "message_queue", "service": "ActiveMQ", "eks_alternative": "Amazon MQ"},
        "ibm.mq": {"type": "message_queue", "service": "IBM MQ", "eks_alternative": "Amazon MQ or keep IBM MQ on-prem via Direct Connect"},
        "oracle": {"type": "database", "service": "Oracle Database", "eks_alternative": "Amazon RDS for Oracle or migrate to Aurora PostgreSQL"},
        "ojdbc": {"type": "database", "service": "Oracle JDBC", "eks_alternative": "Amazon RDS for Oracle or migrate to Aurora PostgreSQL"},
        "ldap": {"type": "identity", "service": "LDAP/Active Directory", "eks_alternative": "AWS Directory Service or Amazon Cognito with LDAP connector"},
        "saml": {"type": "identity", "service": "SAML SSO", "eks_alternative": "Amazon Cognito with SAML federation or keep on-prem IDP via VPN"},
        "jaxws": {"type": "integration", "service": "JAX-WS SOAP", "eks_alternative": "Modernize to REST or maintain SOAP with hybrid connectivity"},
        "websphere": {"type": "platform", "service": "WebSphere", "eks_alternative": "Spring Boot embedded server (Tomcat/Undertow)"},
    }

    for dep in dependencies:
        dep_lower = dep.get("name", "").lower()
        for indicator, details in stateful_indicators.items():
            if indicator in dep_lower:
                stateful_components.append({
                    "dependency": dep["name"],
                    "version": dep.get("version", "unknown"),
                    **details,
                    "recommendation": (
                        f"Use {details['eks_alternative']} as a managed service. "
                        f"Update connection configuration to use Kubernetes Secrets "
                        f"for credentials and ConfigMaps for endpoints."
                    ),
                })

    # Check for known container compatibility issues
    problematic_libs = {
        "java.awt": "GUI library - not available in headless containers",
        "javafx": "GUI framework - not available in containers",
        "native-image": "May require specific base image configuration",
        "jni": "Native code - requires matching container architecture",
        "node-gyp": "Native compilation - requires build tools in container",
        "bcrypt": "Native module - requires compatible build environment",
    }

    for dep in dependencies:
        dep_lower = dep.get("name", "").lower()
        for lib, issue in problematic_libs.items():
            if lib in dep_lower:
                compatibility_issues.append({
                    "dependency": dep["name"],
                    "issue": issue,
                    "severity": "MEDIUM",
                    "recommendation": f"Verify {dep['name']} works in container environment. May need specific base image.",
                })

    result = {
        "dependencies": dependencies,
        "stateful_components": stateful_components,
        "compatibility_issues": compatibility_issues,
        "total_dependencies": len(dependencies),
        "summary": {
            "total_stateful": len(stateful_components),
            "total_compatibility_issues": len(compatibility_issues),
            "dependency_files_found": len(artifacts),
        },
    }

    logger.info(
        "Dependency scan complete: %d deps, %d stateful, %d issues",
        len(dependencies),
        len(stateful_components),
        len(compatibility_issues),
    )

    return result


def _retrieve_dependency_files(s3_prefix: str) -> dict[str, str]:
    """Retrieve dependency manifest files from S3."""
    files = {}
    dep_filenames = {
        "pom.xml", "package.json", "requirements.txt", "Pipfile",
        "build.gradle", "build.gradle.kts", "go.mod", "Cargo.toml",
        "Gemfile", "composer.json", "service-dependencies.yaml",
        "service-dependencies.yml",
    }

    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=s3_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            filename = os.path.basename(key)
            if filename in dep_filenames:
                try:
                    response = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
                    content = response["Body"].read().decode("utf-8", errors="ignore")
                    relative_path = key.replace(s3_prefix, "").lstrip("/")
                    files[relative_path] = content
                except Exception as e:
                    logger.warning("Failed to read %s: %s", key, str(e))

    return files


def _parse_maven_dependencies(content: str) -> list[dict]:
    """Parse Maven pom.xml for dependencies."""
    deps = []
    pattern = r"<dependency>\s*<groupId>(.*?)</groupId>\s*<artifactId>(.*?)</artifactId>\s*(?:<version>(.*?)</version>)?"
    for match in re.finditer(pattern, content, re.DOTALL):
        deps.append({
            "name": f"{match.group(1)}:{match.group(2)}",
            "version": match.group(3) or "managed",
            "type": "maven",
        })
    return deps


def _parse_npm_dependencies(content: str) -> list[dict]:
    """Parse package.json for dependencies."""
    deps = []
    try:
        pkg = json.loads(content)
        for section in ("dependencies", "devDependencies"):
            for name, version in pkg.get(section, {}).items():
                deps.append({"name": name, "version": version, "type": "npm"})
    except json.JSONDecodeError:
        logger.warning("Failed to parse package.json")
    return deps


def _parse_pip_dependencies(content: str) -> list[dict]:
    """Parse requirements.txt for dependencies."""
    deps = []
    for line in content.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and not line.startswith("-"):
            match = re.match(r"([a-zA-Z0-9_-]+)\s*([><=!~]+\s*[\d.]+)?", line)
            if match:
                deps.append({
                    "name": match.group(1),
                    "version": (match.group(2) or "any").strip(),
                    "type": "pip",
                })
    return deps


def _parse_gradle_dependencies(content: str) -> list[dict]:
    """Parse build.gradle for dependencies."""
    deps = []
    pattern = r"(?:implementation|compile|api|runtimeOnly)\s*['\"]([^'\"]+)['\"]"
    for match in re.finditer(pattern, content):
        deps.append({"name": match.group(1), "version": "gradle-managed", "type": "gradle"})
    return deps
