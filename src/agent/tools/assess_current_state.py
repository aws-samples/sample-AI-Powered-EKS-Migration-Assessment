"""
Tool: assess_current_state
Extracts comprehensive current-state infrastructure inventory from application artifacts.
This tool documents WHAT EXISTS TODAY — secrets, storage, networking, auth, compute, etc.
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
def assess_current_state(s3_prefix: str) -> dict[str, Any]:
    """Assess the current state of an application's infrastructure from its artifacts.

    Extracts a complete inventory of the application's current infrastructure:
    secrets, storage, networking, authentication, compute resources, messaging,
    databases, scheduled tasks, and monitoring configuration.

    Args:
        s3_prefix: The S3 key prefix where application artifacts are stored.

    Returns:
        Dictionary containing complete current-state inventory organized by category.
    """
    logger.info("Assessing current state at s3://%s/%s", S3_BUCKET, s3_prefix)

    files = _retrieve_all_files(s3_prefix)
    all_content = "\n".join(files.values())

    result = {
        "files_analyzed": list(files.keys()),
        "secrets_inventory": _extract_secrets(files),
        "storage_inventory": _extract_storage(files),
        "networking_inventory": _extract_networking(files),
        "auth_inventory": _extract_auth(files),
        "compute_resources": _extract_compute(all_content),
        "messaging_inventory": _extract_messaging(files),
        "database_inventory": _extract_databases(files),
        "scheduled_tasks": _extract_scheduled_tasks(files),
        "monitoring_inventory": _extract_monitoring(all_content),
        "upstream_dependencies": _extract_upstream(all_content),
        "downstream_dependencies": _extract_downstream(all_content),
        "certificates": _extract_certificates(all_content),
    }

    logger.info("Current state assessment complete: %d files analyzed", len(files))
    return result


def _retrieve_all_files(s3_prefix: str) -> dict[str, str]:
    """Retrieve all text files from S3."""
    files = {}
    paginator = s3_client.get_paginator("list_objects_v2")

    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=s3_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if obj["Size"] < 1_000_000:
                try:
                    response = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
                    content = response["Body"].read().decode("utf-8", errors="ignore")
                    relative_path = key.replace(s3_prefix, "").lstrip("/")
                    files[relative_path] = content
                except Exception as e:
                    logger.warning("Failed to read %s: %s", key, str(e))

    return files


def _extract_secrets(files: dict) -> list[dict]:
    """Extract all secrets/credentials found in artifacts."""
    secrets = []
    secret_patterns = [
        (r"(\w*(?:password|passwd|pwd)\w*)\s*[=:]\s*(.+)", "password"),
        (r"(\w*(?:secret|token|api.?key)\w*)\s*[=:]\s*(.+)", "token/key"),
        (r"(\w*(?:credentials?)\w*)\s*[=:]\s*(.+)", "credential"),
    ]

    for file_path, content in files.items():
        for line_num, line in enumerate(content.splitlines(), 1):
            for pattern, secret_type in secret_patterns:
                match = re.search(pattern, line, re.IGNORECASE)
                if match and not line.strip().startswith("#") and not line.strip().startswith("//"):
                    name = match.group(1).strip()
                    value = match.group(2).strip().rstrip(",;\"'")
                    # Don't include the actual value, just indicate it exists
                    if len(value) > 2 and value not in ("${", "#{", "$("):
                        secrets.append({
                            "name": name,
                            "type": secret_type,
                            "file": file_path,
                            "line": line_num,
                            "storage_method": "plaintext_in_file",
                        })

    # Deduplicate by name
    seen = set()
    unique_secrets = []
    for s in secrets:
        if s["name"] not in seen:
            seen.add(s["name"])
            unique_secrets.append(s)

    return unique_secrets


def _extract_storage(files: dict) -> list[dict]:
    """Extract storage/volume configurations."""
    storage = []
    all_content = "\n".join(files.values())

    # NFS mounts
    nfs_mounts = re.findall(r"(/mnt/nfs/\S+|/mnt/\S+)", all_content)
    for mount in set(nfs_mounts):
        storage.append({"path": mount, "type": "NFS", "shared": True})

    # Local filesystem paths
    local_paths = re.findall(r"(/opt/\S+|/var/\S+|/tmp/\S+)", all_content)
    for path in set(local_paths):
        if any(x in path for x in ["websphere", "appserver", "reports", "data", "orders"]):
            storage.append({"path": path, "type": "local", "shared": False})

    # Docker volumes
    volume_mounts = re.findall(r"-\s*(\./\S+|/\S+):(/\S+)", all_content)
    for host, container in volume_mounts:
        storage.append({"path": container, "type": "docker_volume", "host_path": host, "shared": False})

    # Named volumes
    named_volumes = re.findall(r"^\s+(\w+_data):", all_content, re.MULTILINE)
    for vol in set(named_volumes):
        storage.append({"path": vol, "type": "named_volume", "shared": False})

    return storage


def _extract_networking(files: dict) -> list[dict]:
    """Extract networking configuration."""
    networking = []
    all_content = "\n".join(files.values())

    # Port mappings
    ports = re.findall(r"[\"']?(\d{2,5}):(\d{2,5})[\"']?", all_content)
    for host_port, container_port in set(ports):
        networking.append({"host_port": host_port, "container_port": container_port, "type": "port_mapping"})

    # EXPOSE directives
    exposed = re.findall(r"EXPOSE\s+(.+)", all_content)
    for ports_str in exposed:
        for p in ports_str.split():
            networking.append({"port": p, "type": "exposed_port"})

    # Network mode
    if "network_mode: host" in all_content:
        networking.append({"type": "network_mode", "mode": "host", "issue": "incompatible_with_eks"})

    # SSL termination
    if re.search(r"ssl|443|https|tls", all_content, re.IGNORECASE):
        networking.append({"type": "ssl", "termination": "external_lb"})

    return networking


def _extract_auth(files: dict) -> list[dict]:
    """Extract authentication/authorization mechanisms."""
    auth = []
    all_content = "\n".join(files.values())

    # LDAP
    ldap_urls = re.findall(r"ldaps?://[\d\.]+:\d+|ldaps?://[\w\.\-]+:\d+", all_content)
    for url in set(ldap_urls):
        auth.append({"mechanism": "LDAP", "endpoint": url, "protocol": "LDAP"})

    # SAML
    saml_urls = re.findall(r"https://[^\s\"']+(?:adfs|saml|sso|federation)[^\s\"']*", all_content, re.IGNORECASE)
    for url in set(saml_urls):
        auth.append({"mechanism": "SAML", "endpoint": url, "protocol": "SAML 2.0"})

    # API Keys
    api_keys = re.findall(r"(?:api[._-]?key|x-api-key)\s*[=:]\s*\S+", all_content, re.IGNORECASE)
    if api_keys:
        auth.append({"mechanism": "API_Key", "count": len(api_keys), "protocol": "HTTP Header"})

    # mTLS
    if re.search(r"mtls|mutual.?tls|client.?cert|keystore|truststore", all_content, re.IGNORECASE):
        auth.append({"mechanism": "mTLS", "protocol": "TLS", "note": "Client certificate authentication"})

    return auth


def _extract_compute(content: str) -> dict:
    """Extract compute resource configuration."""
    compute = {}

    # JVM Heap
    heap_match = re.findall(r"-Xmx(\d+[gGmM])", content)
    if heap_match:
        compute["jvm_max_heap"] = heap_match[0]

    heap_min = re.findall(r"-Xms(\d+[gGmM])", content)
    if heap_min:
        compute["jvm_min_heap"] = heap_min[0]

    # CPU from compose or K8s manifests
    cpu_match = re.findall(r"cpus?:\s*([\d.]+)", content)
    if cpu_match:
        compute["cpu_cores"] = cpu_match[0]

    # CPU from K8s resources
    k8s_cpu = re.findall(r"cpu:\s*[\"']?(\d+m?)[\"']?", content)
    if k8s_cpu:
        compute["k8s_cpu_requests"] = k8s_cpu

    # Memory limit from compose
    mem_match = re.findall(r"mem_limit:\s*(\d+[gGmM])", content)
    if mem_match:
        compute["memory_limit"] = mem_match[0]

    # Memory from K8s resources
    k8s_mem = re.findall(r"memory:\s*[\"']?(\d+[MmGg]i?)[\"']?", content)
    if k8s_mem:
        compute["k8s_memory_requests"] = k8s_mem

    # Thread pools
    thread_match = re.findall(r"(?:max-size|max_size|maxSize|thread.*max)\D*(\d+)", content)
    if thread_match:
        compute["thread_pool_max"] = max(int(x) for x in thread_match)

    # Connection pools
    conn_match = re.findall(r"(?:max-connections|maximum-pool-size|max.?pool)\D*(\d+)", content)
    if conn_match:
        compute["connection_pool_max"] = max(int(x) for x in conn_match)

    # Metaspace
    meta_match = re.findall(r"MaxMetaspaceSize=(\d+[gGmM])", content)
    if meta_match:
        compute["metaspace"] = meta_match[0]

    # Replicas from K8s/compose
    replicas = re.findall(r"replicas:\s*(\d+)", content)
    if replicas:
        compute["replicas"] = max(int(x) for x in replicas)

    return compute


def _extract_messaging(files: dict) -> list[dict]:
    """Extract messaging/queue configurations."""
    messaging = []
    all_content = "\n".join(files.values())

    # IBM MQ
    mq_queues = re.findall(r"[A-Z]+\.[A-Z]+\.Q\b|[A-Z]+\.[A-Z]+\.[A-Z]+", all_content)
    mq_host = re.findall(r"(?:mq|connName)[^\n]*?(\d+\.\d+\.\d+\.\d+)", all_content, re.IGNORECASE)
    if mq_queues or "ibm.mq" in all_content.lower():
        messaging.append({
            "system": "IBM MQ",
            "queues": list(set(q for q in mq_queues if "." in q and q.isupper()))[:10],
            "host": mq_host[0] if mq_host else "unknown",
            "port": "1414",
            "protocol": "MQ Client",
        })

    # Elasticsearch
    es_urls = re.findall(r"http://[\d\.]+:(?:9200|9300)", all_content)
    if es_urls:
        messaging.append({
            "system": "Elasticsearch",
            "endpoints": list(set(es_urls)),
            "protocol": "HTTP/REST",
        })

    # SMTP
    smtp_match = re.findall(r"(?:smtp|mail).*?(\d+\.\d+\.\d+\.\d+)", all_content, re.IGNORECASE)
    if smtp_match:
        messaging.append({"system": "SMTP", "host": smtp_match[0], "port": "25", "protocol": "SMTP"})

    return messaging


def _extract_databases(files: dict) -> list[dict]:
    """Extract database configurations."""
    databases = []
    all_content = "\n".join(files.values())

    # Oracle
    oracle_urls = re.findall(r"jdbc:oracle:[^\s\"']+", all_content)
    if oracle_urls:
        databases.append({
            "type": "Oracle",
            "connection_string": oracle_urls[0][:80],
            "driver": "oracle.jdbc.OracleDriver",
        })

    # PostgreSQL
    pg_urls = re.findall(r"jdbc:postgresql://[^\s\"']+", all_content)
    if pg_urls:
        databases.append({"type": "PostgreSQL", "connection_string": pg_urls[0][:80]})

    # Redis
    redis_nodes = re.findall(r"(\d+\.\d+\.\d+\.\d+:\d{4})", all_content)
    redis_nodes = [n for n in redis_nodes if ":6379" in n or ":6380" in n or ":6381" in n]
    if redis_nodes:
        databases.append({
            "type": "Redis",
            "nodes": list(set(redis_nodes)),
            "mode": "cluster" if len(set(redis_nodes)) > 1 else "standalone",
        })

    return databases


def _extract_scheduled_tasks(files: dict) -> list[dict]:
    """Extract cron/scheduled task configurations."""
    tasks = []

    for file_path, content in files.items():
        # Spring @Scheduled
        scheduled = re.findall(r'@Scheduled\s*\(\s*cron\s*=\s*["\']([^"\']+)["\']', content)
        for cron_expr in scheduled:
            tasks.append({"type": "spring_scheduled", "cron": cron_expr, "file": file_path})

        # Crontab entries
        if "crontab" in file_path.lower() or file_path.endswith(".sh"):
            cron_lines = re.findall(r"^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$", content, re.MULTILINE)
            for schedule, command in cron_lines:
                if not schedule.startswith("#"):
                    tasks.append({"type": "crontab", "cron": schedule, "command": command.strip()[:100], "file": file_path})

    return tasks


def _extract_monitoring(content: str) -> list[dict]:
    """Extract monitoring/observability configuration."""
    monitoring = []

    # Splunk
    if re.search(r"splunk", content, re.IGNORECASE):
        splunk_url = re.findall(r"http://[\d\.]+:8088", content)
        monitoring.append({"tool": "Splunk", "type": "logging", "endpoint": splunk_url[0] if splunk_url else "configured"})

    # Dynatrace
    if re.search(r"dynatrace", content, re.IGNORECASE):
        monitoring.append({"tool": "Dynatrace", "type": "APM"})

    # Prometheus/Actuator
    if re.search(r"actuator|prometheus|micrometer", content, re.IGNORECASE):
        monitoring.append({"tool": "Spring Actuator/Prometheus", "type": "metrics"})

    return monitoring


def _extract_upstream(content: str) -> list[dict]:
    """Extract upstream service dependencies."""
    deps = []
    # URLs that look like service calls
    service_urls = re.findall(r"(?:app\.services\.\w+\.url|SERVICE_URL)\s*=\s*(\S+)", content, re.IGNORECASE)
    http_urls = re.findall(r"(https?://\d+\.\d+\.\d+\.\d+:\d+/\S*)", content)

    for url in set(service_urls + http_urls):
        if "localhost" not in url and "127.0.0.1" not in url:
            deps.append({"endpoint": url[:100], "protocol": "HTTPS" if "https" in url else "HTTP"})

    return deps[:15]  # Limit


def _extract_downstream(content: str) -> list[dict]:
    """Extract downstream consumers."""
    deps = []
    # Look for event/notification patterns
    patterns = re.findall(r"(?:shipping|billing|audit|notification|analytics)\S*(?:url|endpoint|service)\s*=\s*(\S+)", content, re.IGNORECASE)
    for url in set(patterns):
        deps.append({"endpoint": url[:100], "type": "downstream"})

    return deps[:10]


def _extract_certificates(content: str) -> list[dict]:
    """Extract SSL/TLS certificate references."""
    certs = []
    cert_paths = re.findall(r"([\w/\.\-]+\.(?:jks|p12|pem|crt|key))", content)
    for path in set(cert_paths):
        cert_type = "keystore" if ".jks" in path or ".p12" in path else "certificate"
        certs.append({"path": path, "type": cert_type})

    return certs
