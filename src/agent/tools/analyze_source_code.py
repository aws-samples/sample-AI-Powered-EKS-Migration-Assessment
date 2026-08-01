"""
Tool: analyze_source_code
Scans application source code for EKS migration blockers.
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
def analyze_source_code(s3_prefix: str) -> dict[str, Any]:
    """Analyze application source code for EKS migration blockers.

    Scans uploaded application source code for patterns that would prevent
    or complicate running on Amazon EKS, including hardcoded IPs, local
    filesystem dependencies, session state issues, and environment-specific configs.

    Args:
        s3_prefix: The S3 key prefix where application source code is stored.

    Returns:
        Dictionary containing blockers, warnings, and analysis metadata.
    """
    logger.info("Analyzing source code at s3://%s/%s", S3_BUCKET, s3_prefix)

    source_files = _retrieve_source_files(s3_prefix)
    blockers = []
    warnings = []
    info = []

    for file_path, content in source_files.items():
        # Check for hardcoded IP addresses
        ip_matches = re.findall(
            r"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b",
            content,
        )
        # Filter out common non-issue IPs
        ip_matches = [ip for ip in ip_matches if ip not in ("127.0.0.1", "0.0.0.0")]  # nosec B104 — string comparison, not a bind
        if ip_matches:
            blockers.append({
                "file": file_path,
                "type": "hardcoded_ip",
                "severity": "HIGH",
                "details": f"Found hardcoded IPs: {ip_matches}",
                "recommendation": (
                    "Use Kubernetes ConfigMaps or environment variables for service discovery. "
                    "Consider using Kubernetes DNS for internal service communication."
                ),
                "effort_hours": 2,
            })

        # Check for local filesystem writes
        fs_write_patterns = [
            (r"FileWriter|FileOutputStream|BufferedWriter", "Java file write"),
            (r"Files\.write|Files\.copy|Files\.move", "Java NIO file operation"),
            (r"open\s*\([^)]*['\"][wa]['\"]", "Python file write"),
            (r"fs\.writeFile|fs\.appendFile", "Node.js file write"),
            (r"File\.open.*['\"]w", "Ruby file write"),
        ]
        for pattern, desc in fs_write_patterns:
            matches = re.findall(pattern, content)
            if matches:
                blockers.append({
                    "file": file_path,
                    "type": "local_filesystem_write",
                    "severity": "HIGH",
                    "details": f"Local filesystem write detected: {desc}",
                    "recommendation": (
                        "Use Amazon EFS (via CSI driver) for shared persistent storage, "
                        "or Amazon S3 for object storage. Avoid writing to local pod filesystem "
                        "as data is lost on pod restart."
                    ),
                    "effort_hours": 8,
                })
                break

        # Check for in-process session state
        session_patterns = [
            (r"HttpSession|@SessionScoped|@SessionAttributes", "Java HTTP session"),
            (r"session\[|request\.session", "Python/Ruby session"),
            (r"req\.session|express-session", "Node.js session"),
        ]
        for pattern, desc in session_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "in_process_session",
                    "severity": "MEDIUM",
                    "details": f"In-process session state detected: {desc}",
                    "recommendation": (
                        "Externalize session state to Amazon ElastiCache for Redis. "
                        "This enables horizontal scaling and pod rescheduling without session loss."
                    ),
                    "effort_hours": 4,
                })
                break

        # Check for hardcoded hostnames/ports
        hostname_patterns = re.findall(
            r"(?:localhost|127\.0\.0\.1):\d+", content
        )
        if hostname_patterns:
            warnings.append({
                "file": file_path,
                "type": "hardcoded_hostname",
                "severity": "MEDIUM",
                "details": f"Hardcoded localhost references: {hostname_patterns}",
                "recommendation": (
                    "Replace with Kubernetes Service DNS names or environment variables. "
                    "Use ConfigMaps for environment-specific configuration."
                ),
                "effort_hours": 2,
            })

        # Check for environment-specific configurations
        env_patterns = [
            (r"application-prod\.properties|application-dev\.properties", "Spring profiles"),
            (r"\.env\.production|\.env\.development", "Dotenv files"),
        ]
        for pattern, desc in env_patterns:
            if re.search(pattern, content):
                info.append({
                    "file": file_path,
                    "type": "environment_config",
                    "severity": "LOW",
                    "details": f"Environment-specific config detected: {desc}",
                    "recommendation": (
                        "Use Kubernetes ConfigMaps and Secrets for environment-specific values. "
                        "Consider using External Secrets Operator with AWS Secrets Manager."
                    ),
                    "effort_hours": 2,
                })
                break

        # Check for IBM MQ / legacy messaging
        mq_patterns = [
            (r"com\.ibm\.mq|MQQueue|QueueManager|SVRCONN|ibm\.mq", "IBM MQ integration"),
            (r"com\.ibm\.websphere|WsnInitialContextFactory", "WebSphere-specific code"),
            (r"tibco|TibjmsConnectionFactory", "TIBCO EMS messaging"),
        ]
        for pattern, desc in mq_patterns:
            if re.search(pattern, content):
                blockers.append({
                    "file": file_path,
                    "type": "legacy_messaging",
                    "severity": "HIGH",
                    "details": f"Legacy messaging dependency: {desc}",
                    "recommendation": (
                        "Migrate to Amazon MQ (supports ActiveMQ/RabbitMQ protocols) or Amazon MSK (Kafka). "
                        "For IBM MQ specifically: use MQ client libraries in container with Direct Connect "
                        "to on-prem MQ, or bridge to Amazon MQ during phased migration."
                    ),
                    "effort_hours": 16,
                })
                break

        # Check for LDAP/AD authentication
        ldap_patterns = [
            (r"LdapTemplate|LdapCtxFactory|ldap://|LDAP_URL|spring\.ldap", "LDAP/Active Directory auth"),
            (r"saml2|SAML|adfs|FederationMetadata", "SAML/SSO integration"),
        ]
        for pattern, desc in ldap_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "identity_provider_dependency",
                    "severity": "HIGH",
                    "details": f"On-premises identity provider dependency: {desc}",
                    "recommendation": (
                        "IDP may not migrate with the application. Options: "
                        "1) Keep on-prem IDP + AWS Direct Connect/VPN for auth traffic, "
                        "2) Use AWS Directory Service connector, "
                        "3) Migrate to Amazon Cognito with SAML federation. "
                        "Ensure auth latency <50ms via dedicated network path."
                    ),
                    "effort_hours": 12,
                })
                break

        # Check for SOAP/legacy service calls
        soap_patterns = [
            (r"wsdl|SOAPAction|soapenv:Envelope|javax\.xml\.ws", "SOAP web service"),
            (r"JAXBContext|Marshaller|Unmarshaller", "JAXB XML binding"),
        ]
        for pattern, desc in soap_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "legacy_integration",
                    "severity": "MEDIUM",
                    "details": f"Legacy integration pattern: {desc}",
                    "recommendation": (
                        "SOAP services that remain on-prem need hybrid connectivity. "
                        "Use AWS Direct Connect or Site-to-Site VPN. Consider adding "
                        "a service mesh sidecar for mTLS and retry logic. "
                        "Long-term: migrate to REST/gRPC."
                    ),
                    "effort_hours": 8,
                })
                break

        # Check for API Gateway dependencies (APIGEE, DataPower)
        apigw_patterns = [
            (r"apigee|APIGEE|api\.enterprise\.com", "APIGEE API Gateway"),
            (r"datapower|DataPower|IBM.*Gateway", "IBM DataPower Gateway"),
        ]
        for pattern, desc in apigw_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "api_gateway_dependency",
                    "severity": "MEDIUM",
                    "details": f"External API Gateway dependency: {desc}",
                    "recommendation": (
                        "Options: 1) Keep existing gateway, update target server to EKS ALB endpoint, "
                        "2) Migrate to Amazon API Gateway + WAF for full cloud-native stack. "
                        "Consider rate limiting, OAuth policies, and developer portal migration."
                    ),
                    "effort_hours": 8,
                })
                break

        # Check for upstream/downstream service dependencies
        service_call_count = len(re.findall(
            r"https?://\d+\.\d+\.\d+\.\d+|https?://[a-z].*\.internal\.\.corp|HttpURLConnection|RestTemplate|WebClient",
            content
        ))
        if service_call_count > 2:
            warnings.append({
                "file": file_path,
                "type": "service_dependencies",
                "severity": "MEDIUM",
                "details": f"Multiple service dependencies detected ({service_call_count} endpoints). Upstream/downstream services may not migrate simultaneously.",
                "recommendation": (
                    "Map all upstream/downstream dependencies and their migration phases. "
                    "Services remaining on-prem need hybrid connectivity (Direct Connect/VPN). "
                    "Implement circuit breakers (Resilience4j) and retry logic for cross-network calls. "
                    "Use AWS Transit Gateway for routing between EKS and on-prem."
                ),
                "effort_hours": 8,
            })

        # Check for cron jobs / scheduled tasks
        cron_patterns = [
            (r"@Scheduled|cron\s*=|crontab", "Scheduled tasks/cron jobs"),
            (r"\*/\d+\s+\*|0\s+\d+\s+\*\s+\*\s+\*", "Cron expression"),
        ]
        for pattern, desc in cron_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "scheduled_tasks",
                    "severity": "MEDIUM",
                    "details": f"Scheduled tasks detected: {desc}",
                    "recommendation": (
                        "Convert cron jobs to Kubernetes CronJob resources. "
                        "Ensure jobs are idempotent and can tolerate pod rescheduling. "
                        "For jobs needing shared state, use external storage."
                    ),
                    "effort_hours": 4,
                })
                break

        # Check for NFS/shared filesystem mounts
        nfs_patterns = [
            (r"/mnt/nfs|nfs-common|mount.*nfs|NFS_MOUNT", "NFS shared filesystem"),
            (r"VOLUME\s*\[|volumes:|/opt/websphere", "Container volume/platform path"),
        ]
        for pattern, desc in nfs_patterns:
            if re.search(pattern, content):
                blockers.append({
                    "file": file_path,
                    "type": "shared_filesystem",
                    "severity": "HIGH",
                    "details": f"Shared filesystem dependency: {desc}",
                    "recommendation": (
                        "Replace NFS with Amazon EFS (CSI driver) for shared access across pods, "
                        "or Amazon S3 for object storage. EFS provides NFS-compatible interface "
                        "with automatic scaling. For high-IOPS needs, use EBS with ReadWriteOnce."
                    ),
                    "effort_hours": 8,
                })
                break

        # Check for platform-specific code (WebSphere, JBoss, etc.)
        platform_patterns = [
            (r"com\.ibm\.websphere|WAS_HOME|startServer\.sh", "WebSphere Application Server"),
            (r"jboss|wildfly|standalone\.xml", "JBoss/WildFly"),
            (r"weblogic|wls_|AdminServer", "Oracle WebLogic"),
        ]
        for pattern, desc in platform_patterns:
            if re.search(pattern, content):
                blockers.append({
                    "file": file_path,
                    "type": "platform_specific",
                    "severity": "HIGH",
                    "details": f"Platform-specific dependency: {desc}",
                    "recommendation": (
                        "Refactor away from application server dependencies. "
                        "Use embedded server (Spring Boot embedded Tomcat/Undertow). "
                        "Replace JNDI lookups with Spring dependency injection. "
                        "Replace platform-specific monitoring with Prometheus/CloudWatch."
                    ),
                    "effort_hours": 16,
                })
                break

        # Check for OpenShift-specific resources
        openshift_patterns = [
            (r"kind:\s*Route|apiVersion:\s*route\.openshift\.io", "OpenShift Route"),
            (r"kind:\s*DeploymentConfig|apiVersion:\s*apps\.openshift\.io", "OpenShift DeploymentConfig"),
            (r"kind:\s*BuildConfig|apiVersion:\s*build\.openshift\.io", "OpenShift BuildConfig"),
            (r"kind:\s*ImageStream|apiVersion:\s*image\.openshift\.io", "OpenShift ImageStream"),
            (r"SecurityContextConstraints|kind:\s*SCC", "OpenShift SCC"),
        ]
        for pattern, desc in openshift_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "openshift_specific",
                    "severity": "MEDIUM",
                    "details": f"OpenShift-specific resource: {desc}",
                    "recommendation": (
                        "Convert to EKS equivalents: "
                        "Route → Ingress (ALB Ingress Controller), "
                        "DeploymentConfig → Deployment, "
                        "BuildConfig → CodeBuild/CodePipeline, "
                        "ImageStream → ECR, "
                        "SCC → Pod Security Standards (restricted/baseline)."
                    ),
                    "effort_hours": 4,
                })
                break

        # Check for Azure-specific configurations
        azure_patterns = [
            (r"azure-pipelines\.yml|azurePipelines", "Azure DevOps Pipeline"),
            (r"Microsoft\.Azure|azure\.servicebus|azure\.storage", "Azure SDK dependency"),
            (r"aksCluster|azure\.kubernetes|aks\.azure\.com", "Azure AKS specific"),
            (r"azureServiceBus|azure\.messaging", "Azure Service Bus"),
            (r"Azure\.Identity|DefaultAzureCredential|ManagedIdentityCredential", ".NET Azure Identity"),
        ]
        for pattern, desc in azure_patterns:
            if re.search(pattern, content):
                warnings.append({
                    "file": file_path,
                    "type": "azure_specific",
                    "severity": "MEDIUM",
                    "details": f"Azure-specific dependency: {desc}",
                    "recommendation": (
                        "Replace with AWS equivalents: "
                        "Azure DevOps → CodePipeline/CodeBuild, "
                        "Azure Service Bus → Amazon SQS/SNS/MQ, "
                        "Azure Storage → Amazon S3, "
                        "Azure Identity → IRSA (IAM Roles for Service Accounts), "
                        "AKS annotations → EKS/ALB annotations."
                    ),
                    "effort_hours": 6,
                })
                break

        # Check for existing Kubernetes manifests (migration from self-managed)
        k8s_patterns = [
            (r"apiVersion:\s*apps/v1\s+kind:\s*Deployment", "Kubernetes Deployment"),
            (r"apiVersion:\s*v1\s+kind:\s*Service", "Kubernetes Service"),
            (r"apiVersion:\s*networking\.k8s\.io/v1\s+kind:\s*Ingress", "Kubernetes Ingress"),
            (r"apiVersion:\s*v1\s+kind:\s*PersistentVolumeClaim", "PersistentVolumeClaim"),
        ]
        k8s_found = []
        for pattern, desc in k8s_patterns:
            if re.search(pattern, content):
                k8s_found.append(desc)
        if k8s_found:
            info.append({
                "file": file_path,
                "type": "existing_k8s_manifests",
                "severity": "LOW",
                "details": f"Existing Kubernetes manifests found: {k8s_found}",
                "recommendation": (
                    "Review existing manifests for EKS compatibility: "
                    "Update Ingress annotations for ALB Controller, "
                    "replace cloud-specific StorageClass with EBS/EFS CSI, "
                    "add IRSA service account annotations, "
                    "verify Pod Security Standards compliance."
                ),
                "effort_hours": 4,
            })

    result = {
        "blockers": blockers,
        "warnings": warnings,
        "info": info,
        "files_analyzed": len(source_files),
        "summary": {
            "total_issues": len(blockers) + len(warnings) + len(info),
            "high_severity": len(blockers),
            "medium_severity": len(warnings),
            "low_severity": len(info),
        },
    }

    logger.info(
        "Source code analysis complete: %d files, %d blockers, %d warnings",
        len(source_files),
        len(blockers),
        len(warnings),
    )

    return result


def _retrieve_source_files(s3_prefix: str) -> dict[str, str]:
    """Retrieve source files from S3."""
    files = {}
    paginator = s3_client.get_paginator("list_objects_v2")

    # File extensions to analyze
    code_extensions = {
        ".java", ".py", ".js", ".ts", ".go", ".rb", ".cs",
        ".properties", ".yml", ".yaml", ".json", ".xml",
        ".env", ".cfg", ".conf", ".ini", ".sh", ".bash",
    }

    # Also include specific filenames without extensions
    target_filenames = {"crontab", "Makefile", "Procfile"}

    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=s3_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            filename = os.path.basename(key)
            ext = os.path.splitext(key)[1].lower()

            if (ext in code_extensions or filename in target_filenames) and obj["Size"] < 1_000_000:
                try:
                    response = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
                    content = response["Body"].read().decode("utf-8", errors="ignore")
                    relative_path = key.replace(s3_prefix, "").lstrip("/")
                    files[relative_path] = content
                except Exception as e:
                    logger.warning("Failed to read %s: %s", key, str(e))

    return files
