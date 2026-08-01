###############################################################################
# Module: codebuild
# Outputs
###############################################################################

output "agent_build_project_name" {
  description = "CodeBuild project name for agent image"
  value       = aws_codebuild_project.agent.name
}

output "ui_build_project_name" {
  description = "CodeBuild project name for UI image"
  value       = aws_codebuild_project.ui.name
}
