locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  api_fqdn = "${var.api_subdomain}.${var.hosted_zone_name}"
  db_name  = "drproof"

  # Secrets Manager replicas keep the same name and suffix; only the region differs.
  db_secret_arn_secondary = replace(aws_secretsmanager_secret.db.arn, ":${var.primary_region}:", ":${var.secondary_region}:")
  ledger_arn_secondary    = replace(aws_dynamodb_table.ledger.arn, ":${var.primary_region}:", ":${var.secondary_region}:")

  primary_health_url   = "${module.app_primary.default_endpoint}/health"
  secondary_health_url = "${module.app_secondary.default_endpoint}/health"

  global_cluster_arn = "arn:${local.partition}:rds::${local.account_id}:global-cluster:${aws_rds_global_cluster.this.id}"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "dr-evidence"
  }
}

data "aws_route53_zone" "this" {
  provider     = aws.primary
  name         = var.hosted_zone_name
  private_zone = false
}
