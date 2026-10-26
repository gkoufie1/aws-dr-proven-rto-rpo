output "api_url" {
  description = "Public failover hostname clients use."
  value       = "https://${local.api_fqdn}"
}

output "primary_health_url" {
  value = local.primary_health_url
}

output "secondary_health_url" {
  value = local.secondary_health_url
}

output "primary_region" {
  value = var.primary_region
}

output "secondary_region" {
  value = var.secondary_region
}

output "drill_state_machine_arn" {
  value = aws_sfn_state_machine.drill.arn
}

output "failover_state_machine_arn" {
  value = aws_sfn_state_machine.failover.arn
}

output "failback_state_machine_arn" {
  value = aws_sfn_state_machine.failback.arn
}

output "dr_state_table" {
  value = aws_dynamodb_table.dr_state.name
}

output "evidence_bucket" {
  value = aws_s3_bucket.evidence.bucket
}

output "fis_experiment_template_id" {
  value = aws_fis_experiment_template.region_impairment.id
}

output "global_cluster_id" {
  value = aws_rds_global_cluster.this.id
}

output "dashboard_url" {
  value = "https://${var.secondary_region}.console.aws.amazon.com/cloudwatch/home?region=${var.secondary_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.dr.dashboard_name}"
}

output "secondary_cluster_arn" {
  description = "Target for break-glass failover (docs/runbook.md)."
  value       = aws_rds_cluster.secondary.arn
}
