###############################################################################
# Module: kms
# Outputs
###############################################################################

output "key_arn" {
  description = "KMS CMK ARN"
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "KMS CMK ID"
  value       = aws_kms_key.this.key_id
}

output "alias_arn" {
  description = "KMS alias ARN"
  value       = aws_kms_alias.this.arn
}
