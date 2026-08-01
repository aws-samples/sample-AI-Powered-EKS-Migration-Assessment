###############################################################################
# Module: agentcore_endpoint
# Outputs
###############################################################################

output "endpoint_arn" {
  description = "AgentCore Runtime Endpoint ARN"
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.agent_runtime_endpoint_arn
}

output "endpoint_id" {
  description = "AgentCore Runtime Endpoint name (used as identifier)"
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.name
}
