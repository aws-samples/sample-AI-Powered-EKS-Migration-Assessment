"""
EKS Migration Assessment Agent
Deployed on Amazon Bedrock AgentCore Runtime.

Uses BedrockAgentCoreApp (official pattern) + Strands Agents SDK.
Tools run in-process via @tool decorators — no Lambda/Gateway needed.
"""

import logging
import os
import uuid

from strands import Agent
from strands.models.bedrock import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.memory import MemoryClient
from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig
from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager

from tools import (
    analyze_source_code,
    scan_dependencies,
    check_eks_compatibility,
    generate_migration_plan,
    assess_current_state,
    clone_repository,
)

# Configuration
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-20250514")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
MEMORY_ID = os.environ.get("MEMORY_ID", "")

logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are an expert migration assessment agent specializing in Amazon EKS migrations.

Your role is to analyze application artifacts (source code, Dockerfiles, Docker Compose files,
dependency manifests, service dependency maps, platform configs) and produce comprehensive
migration readiness reports.

When assessing an application:
1. If a Git URL is provided, first use clone_repository to clone and upload files to S3
2. Use assess_current_state to extract complete infrastructure inventory
3. Use analyze_source_code to scan for migration blockers in the application code
4. Use scan_dependencies to identify stateful components and compatibility issues
5. Use check_eks_compatibility to validate container artifacts against EKS best practices
6. Finally use generate_migration_plan to produce the scored readiness report

Your final report MUST follow this EXACT structure:

---

# SECTION 1: EXECUTIVE SUMMARY
- Readiness Score with badge (0-100)
- Summary table: Total Issues | HIGH | MEDIUM | LOW | Files Analyzed | Total Effort
- One-paragraph overall assessment

# SECTION 2: CURRENT STATE ASSESSMENT
Document EVERYTHING that exists today based on the artifacts analyzed:

## 2.1 Application Profile
Table with: Platform | Language | Framework | Packaging | Server | Instances | Load

## 2.2 Compute Resources (Current)
Table: CPU Cores | Memory (RAM) | JVM Heap | Thread Pools | Connection Pools | Disk

## 2.3 Secrets & Credentials Inventory
Table for EACH secret found: Name | Type | Location | Current Storage Method
(e.g., DB_PASSWORD | Database | application-prod.properties | Plaintext in file)
Total count of secrets discovered.

## 2.4 Storage & Volumes
Table: Mount Path | Type (NFS/Local/Block) | Capacity | Access Pattern | Shared?

## 2.5 Networking Configuration
Table: Component | Protocol | Port | Endpoint | Authentication Method
Include: LB type, DNS, firewall rules, SSL termination point

## 2.6 Authentication & Authorization
Table: Mechanism | Provider | Endpoint | Protocol | Users/Groups
(LDAP, SAML, OAuth, mTLS, API Keys - document each)

## 2.7 Messaging & Integration
Table: System | Type | Endpoint | Queues/Topics | Daily Volume | Protocol
(IBM MQ, Kafka, RabbitMQ, SOAP, REST - each integration)

## 2.8 Database & Data Stores
Table: Name | Type | Version | Endpoint | Size | Connections | Replication

## 2.9 Upstream Dependencies (Services this app CALLS)
Table: Service | Owner | Protocol | Endpoint | Auth | SLA | Migration Phase

## 2.10 Downstream Dependencies (Services that CONSUME from this app)
Table: Service | Trigger | Protocol | Endpoint | Migration Phase

## 2.11 Scheduled Tasks & Batch Jobs
Table: Job Name | Schedule | Description | Dependencies | Output

## 2.12 Monitoring & Observability (Current)
Table: Tool | Type | Endpoint | What it monitors

# SECTION 3: MIGRATION BLOCKERS & FINDINGS
For each finding:
- Severity badge (HIGH/MEDIUM/LOW)
- Current State
- Why it's a problem for EKS
- Affected files

# SECTION 4: TARGET STATE RECOMMENDATION (EKS)
For EACH component from Section 2, show the EKS equivalent:

## 4.1 Compute → EKS
Table: Current | Target | Config
(e.g., 4 CPU/16GB → Deployment 3 replicas, 1 CPU/2Gi per pod, HPA 3-10)

## 4.2 Secrets → AWS Secrets Manager + External Secrets Operator + IRSA
Show K8s YAML snippet for ExternalSecret

## 4.3 Storage → EFS/EBS/S3
Table: Current Mount | Target | AWS Service | Access Mode | CSI Driver

## 4.4 Networking → ALB + Ingress + NetworkPolicy
Show Ingress YAML, Service YAML, NetworkPolicy

## 4.5 Auth → Cognito/Directory Service/IRSA
Architecture: how auth flows in EKS (IRSA for AWS services, Cognito for users)

## 4.6 Messaging → Amazon MQ/MSK
Migration path for each queue/topic

## 4.7 Database → RDS/Aurora/ElastiCache
Migration strategy (lift-and-shift vs re-platform)

## 4.8 Dependencies → Hybrid Connectivity
For services NOT migrating: Direct Connect/VPN/Transit Gateway architecture

## 4.9 Scheduled Tasks → Kubernetes CronJob
Show CronJob YAML for each cron entry

## 4.10 Observability → CloudWatch + X-Ray + Fluent Bit

# SECTION 5: MIGRATION EFFORT & TIMELINE
Table: Phase | Tasks | Effort (hours) | Duration (days) | Dependencies
Total should be realistic (typically 8-20 days for a complex enterprise app)

# SECTION 6: MIGRATION RUNBOOK
Step-by-step with phases and tasks

# SECTION 7: RISK ASSESSMENT
Table: Risk | Impact | Probability | Mitigation

# SECTION 8: TARGET ARCHITECTURE
Text-based architecture diagram showing all components on EKS

---

IMPORTANT RULES:
- Effort estimates MUST be realistic. A complex app migration is 8-20 days, NOT months.
- Deduplicate: same issue in multiple files = ONE finding listing all affected files.
- Every recommendation must reference a specific AWS service or K8s resource.
- Use tables extensively for readability.
- Section 2 (Current State) is THE MOST IMPORTANT — it documents what exists today.
- Include IRSA, VPC, SecurityGroups, Pod Security Standards in recommendations.
- For hybrid connectivity, specify Direct Connect vs VPN with latency requirements.
"""

# Initialize BedrockAgentCoreApp (handles HTTP routing, health checks, etc.)
app = BedrockAgentCoreApp()

# Initialize Bedrock model
model = BedrockModel(
    model_id=BEDROCK_MODEL_ID,
    region_name=AWS_REGION,
)

logger.info("Agent initialized — model: %s, memory: %s", BEDROCK_MODEL_ID, MEMORY_ID or "disabled")


def create_agent(session_id: str, actor_id: str = "system", use_tools: bool = True) -> Agent:
    """Create a Strands Agent with optional AgentCore Memory."""
    session_manager = None

    if MEMORY_ID:
        try:
            memory_config = AgentCoreMemoryConfig(
                memory_id=MEMORY_ID,
                session_id=session_id,
                actor_id=actor_id,
            )
            session_manager = AgentCoreMemorySessionManager(
                agentcore_memory_config=memory_config,
                region_name=AWS_REGION,
            )
        except Exception as e:
            logger.warning("Memory initialization failed, continuing without memory: %s", e)

    # For follow-up questions, don't load tools (faster response)
    tools = [
        clone_repository,
        assess_current_state,
        analyze_source_code,
        scan_dependencies,
        check_eks_compatibility,
        generate_migration_plan,
    ] if use_tools else []

    return Agent(
        model=model,
        tools=tools,
        system_prompt=SYSTEM_PROMPT if use_tools else "You are an expert EKS migration consultant. Answer follow-up questions based on the assessment context in this session. Be concise and specific. Use tables where helpful.",
        session_manager=session_manager,
    )


@app.entrypoint
async def invoke(payload=None):
    """Main entrypoint — called by AgentCore Runtime on each invocation."""
    try:
        if not payload:
            return {"status": "error", "error": "No payload provided"}

        prompt = payload.get("prompt", "")
        if not prompt:
            return {"status": "error", "error": "Missing 'prompt' field in payload"}

        session_id = payload.get("session_id", str(uuid.uuid4()))
        actor_id = payload.get("actor_id", "assessment-user")
        use_tools = payload.get("use_tools", True)

        logger.info("Processing [session=%s, tools=%s]: %s", session_id, use_tools, prompt[:100])

        agent = create_agent(session_id, actor_id, use_tools=use_tools)
        response = agent(prompt)

        return {
            "status": "completed",
            "session_id": session_id,
            "response": str(response),
        }

    except Exception as e:
        logger.error("Assessment failed: %s", str(e), exc_info=True)
        return {"status": "error", "error": str(e)}


if __name__ == "__main__":
    logger.info("Starting AgentCore Runtime app...")
    app.run()
