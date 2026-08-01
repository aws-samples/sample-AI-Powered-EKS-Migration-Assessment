"""
EKS Migration Assessment Agent - Streamlit UI (Phase 2)
Features: Chat interface, follow-up questions, Git URL support, file upload.
Hosted on ECS Fargate, calls AgentCore Runtime directly via AWS SDK.
"""

import json
import os
import time
import uuid
from datetime import datetime

import boto3
import streamlit as st

# Configuration
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
AGENT_RUNTIME_ID = os.environ.get("AGENT_RUNTIME_ID", "")
AGENT_ENDPOINT_ID = os.environ.get("AGENT_ENDPOINT_ID", "")
S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "")
DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "")

# AWS Clients
s3_client = boto3.client("s3", region_name=AWS_REGION)
sts_client = boto3.client("sts", region_name=AWS_REGION)
from botocore.config import Config
agentcore_config = Config(read_timeout=300, connect_timeout=10, retries={"max_attempts": 1})
agentcore_client = boto3.client("bedrock-agentcore", region_name=AWS_REGION, config=agentcore_config)
ACCOUNT_ID = sts_client.get_caller_identity()["Account"]
AGENT_RUNTIME_ARN = f"arn:aws:bedrock-agentcore:{AWS_REGION}:{ACCOUNT_ID}:runtime/{AGENT_RUNTIME_ID}"


def upload_artifacts_to_s3(uploaded_files, app_name: str) -> str:
    """Upload user files to S3 and return the prefix."""
    session_prefix = st.session_state.get("s3_prefix", "")
    if session_prefix:
        return session_prefix

    assessment_id = str(uuid.uuid4())[:8]
    s3_prefix = f"assessments/{app_name}/{assessment_id}/"

    for uploaded_file in uploaded_files:
        key = f"{s3_prefix}{uploaded_file.name}"
        s3_client.put_object(Bucket=S3_BUCKET, Key=key, Body=uploaded_file.getvalue())

    st.session_state["s3_prefix"] = s3_prefix
    return s3_prefix


def invoke_agent(prompt: str, use_tools: bool = True) -> str:
    """Invoke the AgentCore Runtime and return the response."""
    session_id = st.session_state.get("agent_session_id", str(uuid.uuid4()))
    st.session_state["agent_session_id"] = session_id

    payload = json.dumps({
        "prompt": prompt,
        "session_id": session_id,
        "use_tools": use_tools,
    }).encode("utf-8")

    try:
        response = agentcore_client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_RUNTIME_ARN,
            payload=payload,
        )

        result_text = ""
        if "response" in response:
            raw = response["response"].read().decode("utf-8")
            try:
                parsed = json.loads(raw)
                result_text = parsed.get("response", raw)
            except json.JSONDecodeError:
                result_text = raw

        return result_text if result_text else "No response received from agent."

    except Exception as e:
        return f"Error invoking agent: {str(e)}"


def init_session_state():
    """Initialize session state variables."""
    if "messages" not in st.session_state:
        st.session_state["messages"] = []
    if "assessment_started" not in st.session_state:
        st.session_state["assessment_started"] = False
    if "app_name" not in st.session_state:
        st.session_state["app_name"] = ""
    if "s3_prefix" not in st.session_state:
        st.session_state["s3_prefix"] = ""
    if "agent_session_id" not in st.session_state:
        st.session_state["agent_session_id"] = str(uuid.uuid4())


def render_header():
    """Render the app header."""
    st.set_page_config(
        page_title="EKS Migration Assessment",
        page_icon="🚀",
        layout="wide",
    )
    st.title("🚀 AI-Powered EKS Migration Assessment")
    st.markdown(
        "Upload application artifacts or provide a Git URL, get an instant migration "
        "readiness report, and ask follow-up questions."
    )
    st.divider()


def render_sidebar():
    """Render the sidebar with configuration and history."""
    with st.sidebar:
        st.header("⚙️ Configuration")
        st.text_input("Agent Runtime ID", value=AGENT_RUNTIME_ID, disabled=True)
        st.text_input("S3 Bucket", value=S3_BUCKET, disabled=True)
        st.text_input("Region", value=AWS_REGION, disabled=True)
        st.text_input("Session ID", value=st.session_state.get("agent_session_id", ""), disabled=True)

        st.divider()
        st.header("📖 How to Use")
        st.markdown("""
        1. Enter your application name
        2. Upload files **or** provide a Git URL
        3. Add context (platform, load, constraints)
        4. Click **Run Assessment**
        5. Ask follow-up questions in chat
        6. Download report (HTML/PDF/Markdown)
        """)

        st.divider()
        st.header("🌐 Supported Platforms")
        st.markdown("""
        - Red Hat OpenShift
        - Azure (AKS / VMs)
        - On-premises / Bare-metal
        - Self-managed Kubernetes
        - AWS ECS / Docker Swarm
        - Google Cloud (GKE)
        """)

        st.divider()
        if st.button("🗑️ New Assessment", use_container_width=True):
            st.session_state["messages"] = []
            st.session_state["assessment_started"] = False
            st.session_state["app_name"] = ""
            st.session_state["s3_prefix"] = ""
            st.session_state["agent_session_id"] = str(uuid.uuid4())
            st.rerun()

        st.divider()
        render_history()


def render_input_form():
    """Render the application input form."""
    st.subheader("📦 Application Details")

    col1, col2 = st.columns([2, 1])
    with col1:
        app_name = st.text_input(
            "Application Name",
            placeholder="e.g., order-management-service",
            help="A descriptive name for the application being assessed",
        )
    with col2:
        app_type = st.selectbox(
            "Application Type",
            ["Java Spring Boot", "Java EE / WebSphere", "Python Flask/Django",
             "Node.js Express", "Go", ".NET", "Other"],
        )

    st.subheader("📤 Upload Artifacts")

    tab1, tab2 = st.tabs(["📁 File Upload", "🔗 Git Repository URL"])

    uploaded_files = None
    git_url = ""
    git_token = ""

    with tab1:
        uploaded_files = st.file_uploader(
            "Upload Application Artifacts",
            accept_multiple_files=True,
            help="Upload source code, Dockerfiles, compose files, configs, and dependency manifests",
        )
        if uploaded_files:
            st.markdown(f"**{len(uploaded_files)} files selected:**")
            file_cols = st.columns(4)
            for i, f in enumerate(uploaded_files):
                with file_cols[i % 4]:
                    st.text(f"📄 {f.name}")

    with tab2:
        git_url = st.text_input(
            "Git Repository URL",
            placeholder="https://github.com/org/repo.git",
            help="Public or private repository URL",
        )
        col_branch, col_token = st.columns(2)
        with col_branch:
            git_branch = st.text_input(
                "Branch",
                value="main",
                help="Branch to analyze (e.g., main, master, develop)",
            )
        with col_token:
            git_token = st.text_input(
                "Access Token (private repos only)",
                type="password",
                placeholder="ghp_xxxx or PAT",
                help="GitHub PAT or GitLab token. Leave empty for public repos.",
            )
        if git_url:
            repo_type = "🔒 Private" if git_token else "🌐 Public"
            st.success(f"✅ {repo_type} Repository: `{git_url}` (branch: `{git_branch}`)")
    additional_context = st.text_area(
        "Additional Context (optional)",
        placeholder="e.g., Deployed on OpenShift 4.12 on Azure, uses IBM MQ for messaging, "
                    "LDAP for auth, 2000 RPS peak, migrating from Azure to AWS EKS...",
        help="Platform details, load characteristics, migration constraints",
    )

    return app_name, app_type, uploaded_files, git_url, git_branch, git_token, additional_context


def render_chat():
    """Render the chat interface for follow-up questions."""
    # Display message history
    for msg in st.session_state["messages"]:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    # Chat input for follow-ups
    if st.session_state["assessment_started"]:
        if prompt := st.chat_input("Ask a follow-up question about the assessment..."):
            # Add user message
            st.session_state["messages"].append({"role": "user", "content": prompt})
            with st.chat_message("user"):
                st.markdown(prompt)

            # Get agent response
            with st.chat_message("assistant"):
                with st.spinner("Thinking..."):
                    # Include assessment context + ask follow-up
                    # Get the first assistant message (full report)
                    assessment_context = ""
                    for msg in st.session_state["messages"]:
                        if msg["role"] == "assistant":
                            assessment_context = msg["content"]
                            break

                    # Truncate to fit token limits but keep key data
                    context_summary = assessment_context[:8000] if assessment_context else ""

                    context_prompt = (
                        f"You previously assessed '{st.session_state['app_name']}' and produced this report:\n\n"
                        f"{context_summary}\n\n---\n\n"
                        f"Based on the above assessment, answer this follow-up question concisely "
                        f"with specific details from the assessment. Do NOT use any tools. "
                        f"Question: {prompt}"
                    )
                    response = invoke_agent(context_prompt, use_tools=False)
                    st.markdown(response)

            st.session_state["messages"].append({"role": "assistant", "content": response})


def render_history():
    """Render past assessments from DynamoDB."""
    st.header("📜 History")

    if not DYNAMODB_TABLE:
        st.info("No history configured.")
        return

    try:
        dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.scan(Limit=5)
        items = response.get("Items", [])

        if not items:
            st.info("No assessments yet.")
            return

        for item in sorted(items, key=lambda x: x.get("created_at", ""), reverse=True):
            score = int(item.get("readiness_score", 0))
            emoji = "🟢" if score >= 80 else "🟡" if score >= 50 else "🔴"
            st.text(f"{emoji} {item.get('app_name', '?')} — {score}/100")

    except Exception as e:
        st.caption(f"History unavailable: {e}")


def check_authentication():
    """App-level authentication using Cognito USER_PASSWORD_AUTH flow."""
    if not os.environ.get("COGNITO_USER_POOL_ID"):
        return True  # Auth disabled

    if st.session_state.get("authenticated"):
        return True

    st.title("🔐 EKS Migration Assessment - Login")
    st.markdown("Enter your credentials to access the assessment tool.")

    with st.form("login_form"):
        email = st.text_input("Email")
        password = st.text_input("Password", type="password")
        submitted = st.form_submit_button("Login", use_container_width=True)

        if submitted and email and password:
            try:
                cognito_client = boto3.client("cognito-idp", region_name=AWS_REGION)
                response = cognito_client.initiate_auth(
                    ClientId=os.environ.get("COGNITO_CLIENT_ID", ""),
                    AuthFlow="USER_PASSWORD_AUTH",
                    AuthParameters={"USERNAME": email, "PASSWORD": password},
                )
                if response.get("AuthenticationResult"):
                    st.session_state["authenticated"] = True
                    st.session_state["user_email"] = email
                    st.rerun()
                elif response.get("ChallengeName") == "NEW_PASSWORD_REQUIRED":
                    st.warning("Password change required. Contact admin.")
            except Exception as e:
                error_msg = str(e)
                if "NotAuthorizedException" in error_msg:
                    st.error("Invalid email or password.")
                elif "UserNotFoundException" in error_msg:
                    st.error("User not found.")
                else:
                    st.error(f"Login failed: {error_msg}")

    return False


def main():
    """Main application entry point."""
    render_header()
    init_session_state()

    # Check authentication (skipped if COGNITO_USER_POOL_ID not set)
    if not check_authentication():
        return

    render_sidebar()

    if not st.session_state["assessment_started"]:
        # Show input form
        app_name, app_type, uploaded_files, git_url, git_branch, git_token, additional_context = render_input_form()

        if st.button("🔍 Run Assessment", type="primary", use_container_width=True):
            if not app_name:
                st.error("Please enter an application name.")
                return
            if not uploaded_files and not git_url:
                st.error("Please upload files or provide a Git repository URL.")
                return

            st.session_state["app_name"] = app_name

            with st.status("Running assessment...", expanded=True) as status:
                if git_url:
                    # Git URL mode: pass URL directly to agent
                    st.write(f"🔗 Repository: `{git_url}` (branch: `{git_branch}`)")
                    st.write("🤖 Invoking assessment agent...")
                    s3_prefix = f"git/{app_name}/"
                    st.session_state["s3_prefix"] = s3_prefix

                    # Build clone URL with token if provided
                    clone_url = git_url
                    if git_token:
                        # Insert token into URL: https://token@github.com/org/repo.git
                        clone_url = git_url.replace("https://", f"https://{git_token}@")

                    prompt = (
                        f"Assess the application '{app_name}' from Git repository '{clone_url}' (branch: '{git_branch}'). "
                        f"Clone the repository, analyze the source code, dependencies, Dockerfiles, "
                        f"and configuration files for migration readiness to Amazon EKS. "
                        f"Produce a comprehensive migration readiness report with scored findings "
                        f"and a step-by-step migration runbook. "
                        f"Application type: {app_type}. {additional_context}"
                    )
                else:
                    # File upload mode
                    st.write("📤 Uploading artifacts to S3...")
                    s3_prefix = upload_artifacts_to_s3(uploaded_files, app_name)
                    st.write(f"✅ Uploaded {len(uploaded_files)} files to `{s3_prefix}`")
                    st.write("🤖 Invoking assessment agent (this may take 1-2 minutes)...")

                    prompt = (
                        f"Assess the application '{app_name}' stored at S3 prefix '{s3_prefix}' "
                        f"in bucket '{S3_BUCKET}' for migration readiness to Amazon EKS. "
                        f"Analyze the source code, dependencies, Dockerfiles, and configuration files. "
                        f"Produce a comprehensive migration readiness report with scored findings "
                        f"and a step-by-step migration runbook. "
                        f"Application type: {app_type}. {additional_context}"
                    )

                response = invoke_agent(prompt)
                status.update(label="Assessment complete!", state="complete")

            # Store in chat history
            st.session_state["messages"].append({
                "role": "assistant",
                "content": response,
            })
            st.session_state["assessment_started"] = True
            st.rerun()

    else:
        # Show chat interface with assessment results and follow-up
        st.info(
            f"📋 Assessment for **{st.session_state['app_name']}** | "
            f"Session: `{st.session_state['agent_session_id'][:8]}...` | "
            f"Ask follow-up questions below."
        )
        render_chat()

        # Download buttons
        if st.session_state["messages"]:
            full_report = "\n\n---\n\n".join(
                msg["content"] for msg in st.session_state["messages"] if msg["role"] == "assistant"
            )

            col1, col2 = st.columns(2)
            with col1:
                st.download_button(
                    label="📥 Download Report (Markdown)",
                    data=full_report,
                    file_name=f"eks-assessment-{st.session_state['app_name']}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.md",
                    mime="text/markdown",
                )
            with col2:
                # Generate HTML for PDF printing
                import markdown
                html_content = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>EKS Migration Assessment - {st.session_state['app_name']}</title>
<style>
  body {{ font-family: -apple-system, Arial, sans-serif; max-width: 900px; margin: 0 auto; padding: 40px; line-height: 1.6; }}
  h1 {{ color: #232f3e; border-bottom: 3px solid #ff9900; padding-bottom: 10px; }}
  h2 {{ color: #232f3e; border-bottom: 1px solid #ddd; padding-bottom: 5px; margin-top: 30px; }}
  h3 {{ color: #545b64; }}
  table {{ border-collapse: collapse; width: 100%; margin: 15px 0; }}
  th, td {{ border: 1px solid #ddd; padding: 10px; text-align: left; }}
  th {{ background: #232f3e; color: white; }}
  tr:nth-child(even) {{ background: #f9f9f9; }}
  code {{ background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }}
  pre {{ background: #1a1a2e; color: #e0e0e0; padding: 15px; border-radius: 5px; overflow-x: auto; }}
  .score-badge {{ display: inline-block; padding: 5px 15px; border-radius: 20px; font-weight: bold; color: white; background: #d32f2f; }}
  @media print {{ body {{ padding: 20px; }} }}
</style>
</head><body>
{markdown.markdown(full_report, extensions=['tables', 'fenced_code'])}
<footer style="margin-top:40px; padding-top:20px; border-top:1px solid #ddd; color:#666; font-size:0.8em;">
  Generated by AI-Powered EKS Migration Assessment Agent | Amazon Bedrock AgentCore | {datetime.now().strftime('%Y-%m-%d %H:%M')}
</footer>
</body></html>"""
                st.download_button(
                    label="📄 Download Report (HTML/PDF)",
                    data=html_content,
                    file_name=f"eks-assessment-{st.session_state['app_name']}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.html",
                    mime="text/html",
                    help="Open in browser and use Print → Save as PDF",
                )


if __name__ == "__main__":
    main()
