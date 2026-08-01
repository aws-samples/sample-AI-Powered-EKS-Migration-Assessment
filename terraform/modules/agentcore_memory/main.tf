###############################################################################
# Module: agentcore_memory
# AgentCore Memory - persistent short-term + long-term memory for the agent
#
# Strategies:
#   - Semantic: extracts facts from conversations for cross-session recall
#   - Summarization: summarizes sessions for quick context retrieval
#   - User Preference: learns user preferences over time
#
# The Strands Agent SDK integrates with this via AgentCoreMemorySessionManager
###############################################################################

resource "aws_bedrockagentcore_memory" "this" {
  name                      = replace("${var.project_name}_memory", "-", "_")
  description               = "Memory for EKS migration assessment agent - retains assessment context across sessions"
  event_expiry_duration     = var.event_expiry_days
  memory_execution_role_arn = var.execution_role_arn

  tags = merge(var.tags, {
    Name = "${var.project_name}-memory"
  })
}
