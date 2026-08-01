###############################################################################
# Module: agentcore_endpoint
# AgentCore Runtime Endpoint - the invoke URL used by the UI to call the agent
#
# The endpoint provides a stable, network-accessible URL for invoking the agent.
# The UI (ECS) calls this endpoint using AWS SDK with IAM/SigV4 auth.
###############################################################################

resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  name             = replace("${var.project_name}_endpoint", "-", "_")
  agent_runtime_id = var.agent_runtime_id
  description      = "Invoke endpoint for EKS migration assessment agent"

  tags = merge(var.tags, {
    Name = "${var.project_name}-endpoint"
  })
}
