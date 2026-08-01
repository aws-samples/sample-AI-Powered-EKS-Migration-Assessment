#!/usr/bin/env python3
"""
Invoke the EKS Migration Assessment Agent.
Usage: python invoke_agent.py --app-name my-app --s3-prefix assessments/my-app/
"""

import argparse
import json
import sys

import boto3


def invoke_assessment(agent_runtime_id: str, app_name: str, s3_prefix: str, region: str = "us-east-1"):
    """Invoke the assessment agent via AgentCore Runtime endpoint."""

    client = boto3.client("bedrock-agentcore", region_name=region)

    prompt = (
        f"Assess the application '{app_name}' stored at s3 prefix '{s3_prefix}' "
        f"for migration readiness to Amazon EKS. Analyze the source code, dependencies, "
        f"Dockerfiles, and configuration files. Produce a comprehensive migration "
        f"readiness report with scored findings and a step-by-step migration runbook."
    )

    print(f"Invoking assessment for: {app_name}")
    print(f"S3 prefix: {s3_prefix}")
    print(f"Agent Runtime: {agent_runtime_id}")
    print("-" * 60)

    response = client.invoke_agent_runtime(
        agentRuntimeId=agent_runtime_id,
        input={"text": prompt},
    )

    # Process streaming response
    result_text = ""
    for event in response.get("output", {}).get("stream", []):
        if "chunk" in event:
            chunk_text = event["chunk"].get("text", "")
            result_text += chunk_text
            print(chunk_text, end="", flush=True)

    print("\n" + "-" * 60)
    print("Assessment complete.")

    return result_text


def main():
    parser = argparse.ArgumentParser(description="Invoke EKS Migration Assessment Agent")
    parser.add_argument("--runtime-id", required=True, help="AgentCore Runtime ID")
    parser.add_argument("--app-name", required=True, help="Application name to assess")
    parser.add_argument("--s3-prefix", required=True, help="S3 prefix where app artifacts are stored")
    parser.add_argument("--region", default="us-east-1", help="AWS Region")

    args = parser.parse_args()

    try:
        result = invoke_assessment(
            agent_runtime_id=args.runtime_id,
            app_name=args.app_name,
            s3_prefix=args.s3_prefix,
            region=args.region,
        )
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
