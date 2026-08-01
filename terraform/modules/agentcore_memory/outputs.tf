###############################################################################
# Module: agentcore_memory
# Outputs
###############################################################################

output "memory_id" {
  description = "AgentCore Memory ID - pass to agent as env var"
  value       = aws_bedrockagentcore_memory.this.id
}

output "memory_arn" {
  description = "AgentCore Memory ARN"
  value       = aws_bedrockagentcore_memory.this.arn
}
