"""
Tool: clone_repository
Clones a Git repository and uploads source files to S3 for analysis.
"""

import logging
import os
import shutil
import subprocess
import tempfile
import uuid
from typing import Any

import boto3
from strands import tool

logger = logging.getLogger(__name__)

s3_client = boto3.client("s3")
S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "")

# File extensions to upload for analysis
ANALYZABLE_EXTENSIONS = {
    ".java", ".py", ".js", ".ts", ".go", ".rb", ".cs", ".kt", ".scala",
    ".properties", ".yml", ".yaml", ".json", ".xml", ".toml",
    ".env", ".cfg", ".conf", ".ini", ".sh", ".bash",
    ".tf", ".hcl", ".csproj", ".sln",
}

ANALYZABLE_FILENAMES = {
    "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
    "pom.xml", "package.json", "requirements.txt", "Pipfile",
    "build.gradle", "build.gradle.kts", "go.mod", "Cargo.toml",
    "Gemfile", "composer.json", "Makefile", "Procfile",
    "crontab", "Jenkinsfile", ".dockerignore",
    "values.yaml", "Chart.yaml", "kustomization.yaml",
    "web.config", "appsettings.json",
}


@tool
def clone_repository(git_url: str, branch: str = "main", app_name: str = "app") -> dict[str, Any]:
    """Clone a Git repository and upload relevant source files to S3 for analysis.

    Clones the specified public Git repository, identifies analyzable files
    (source code, configs, Dockerfiles, dependency manifests), and uploads
    them to S3 for the other assessment tools to process.

    Args:
        git_url: Public Git repository URL (https://github.com/org/repo.git)
        branch: Branch to clone (default: main)
        app_name: Application name for S3 prefix organization

    Returns:
        Dictionary containing S3 prefix, files uploaded count, and file list.
    """
    logger.info("Cloning repository: %s (branch: %s)", git_url, branch)

    tmpdir = tempfile.mkdtemp(prefix="repo_")
    try:
        # Clone repository (shallow for speed)
        result = subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", branch, git_url, tmpdir + "/repo"],
            capture_output=True, text=True, timeout=120,
        )

        if result.returncode != 0:
            # Try without branch (default branch)
            result = subprocess.run(
                ["git", "clone", "--depth", "1", git_url, tmpdir + "/repo"],
                capture_output=True, text=True, timeout=120,
            )
            if result.returncode != 0:
                return {
                    "status": "error",
                    "error": f"Failed to clone repository: {result.stderr[:500]}",
                }

        repo_dir = tmpdir + "/repo"
        assessment_id = str(uuid.uuid4())[:8]
        s3_prefix = f"assessments/{app_name}/{assessment_id}/"

        # Find and upload analyzable files
        uploaded_files = []
        for root, dirs, files in os.walk(repo_dir):
            # Skip hidden dirs, node_modules, target, build, vendor
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in
                       ("node_modules", "target", "build", "dist", "vendor", "__pycache__", ".git")]

            for filename in files:
                filepath = os.path.join(root, filename)
                ext = os.path.splitext(filename)[1].lower()

                if filename in ANALYZABLE_FILENAMES or ext in ANALYZABLE_EXTENSIONS:
                    # Skip files > 500KB
                    if os.path.getsize(filepath) > 500_000:
                        continue

                    relative_path = os.path.relpath(filepath, repo_dir)
                    s3_key = f"{s3_prefix}{relative_path}"

                    try:
                        with open(filepath, "rb") as f:
                            s3_client.put_object(Bucket=S3_BUCKET, Key=s3_key, Body=f.read())
                        uploaded_files.append(relative_path)
                    except Exception as e:
                        logger.warning("Failed to upload %s: %s", relative_path, str(e))

        logger.info("Repository cloned: %d files uploaded to s3://%s/%s", len(uploaded_files), S3_BUCKET, s3_prefix)

        return {
            "status": "success",
            "s3_prefix": s3_prefix,
            "s3_bucket": S3_BUCKET,
            "files_uploaded": len(uploaded_files),
            "files": uploaded_files[:50],  # Limit response size
            "repository": git_url,
            "branch": branch,
        }

    except subprocess.TimeoutExpired:
        return {"status": "error", "error": "Repository clone timed out (>120s). Repository may be too large."}
    except Exception as e:
        return {"status": "error", "error": str(e)}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
