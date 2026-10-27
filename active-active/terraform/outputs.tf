output "api_url" {
  value = "https://${local.api_fqdn}"
}

output "east_health_url" {
  value = "${module.app_east.default_endpoint}/health"
}

output "west_health_url" {
  value = "${module.app_west.default_endpoint}/health"
}

output "east_region" {
  value = var.east_region
}

output "west_region" {
  value = var.west_region
}

output "witness_region" {
  value = var.witness_region
}

output "dsql_endpoints" {
  value = local.dsql_endpoint
}

output "dsql_cluster_ids" {
  value = {
    (var.east_region) = aws_dsql_cluster.east.identifier
    (var.west_region) = aws_dsql_cluster.west.identifier
  }
}

output "evidence_bucket" {
  value = aws_s3_bucket.evidence.bucket
}

output "prober_east_name" {
  value = module.prober_east.name
}

output "prober_west_name" {
  value = module.prober_west.name
}

output "analyzer_name" {
  value = module.analyzer.name
}

output "fis_template_id" {
  value = aws_fis_experiment_template.east_impairment.id
}

output "dashboard_url" {
  value = "https://${var.east_region}.console.aws.amazon.com/cloudwatch/home?region=${var.east_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}
