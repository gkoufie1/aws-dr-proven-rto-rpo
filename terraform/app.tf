# --- Lambda packages ---------------------------------------------------------

locals {
  functions = toset(["app", "watchdog", "prober", "analyzer", "drill_control"])
}

data "archive_file" "fn" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${path.module}/../src/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"
  excludes    = ["__pycache__", "**/__pycache__/**", "*.pyc"]
}

# --- Regional application stacks --------------------------------------------

data "aws_ssm_parameter" "fis_layer_primary" {
  provider = aws.primary
  name     = "/aws/service/fis/lambda-extension/AWS-FIS-extension-x86_64/1.x.x"
}

module "app_primary" {
  source    = "./modules/regional-app"
  providers = { aws = aws.primary }

  name               = "${local.name}-primary"
  region_role        = "primary"
  api_fqdn           = local.api_fqdn
  hosted_zone_id     = data.aws_route53_zone.this.zone_id
  package_path       = data.archive_file.fn["app"].output_path
  package_hash       = data.archive_file.fn["app"].output_base64sha256
  db_cluster_arn     = aws_rds_cluster.primary.arn
  db_secret_arn      = aws_secretsmanager_secret.db.arn
  db_name            = local.db_name
  table_name         = aws_dynamodb_table.ledger.name
  table_arn          = aws_dynamodb_table.ledger.arn
  kms_key_arn        = aws_kms_key.primary.arn
  log_retention_days = var.log_retention_days

  # Only the primary is a fault-injection target.
  fis_enabled       = true
  fis_layer_arn     = data.aws_ssm_parameter.fis_layer_primary.insecure_value
  fis_config_bucket = aws_s3_bucket.fis_config.bucket
}

module "app_secondary" {
  source    = "./modules/regional-app"
  providers = { aws = aws.secondary }

  name               = "${local.name}-secondary"
  region_role        = "secondary"
  api_fqdn           = local.api_fqdn
  hosted_zone_id     = data.aws_route53_zone.this.zone_id
  package_path       = data.archive_file.fn["app"].output_path
  package_hash       = data.archive_file.fn["app"].output_base64sha256
  db_cluster_arn     = aws_rds_cluster.secondary.arn
  db_secret_arn      = local.db_secret_arn_secondary
  db_name            = local.db_name
  table_name         = aws_dynamodb_table.ledger.name
  table_arn          = local.ledger_arn_secondary
  kms_key_arn        = aws_kms_key.secondary.arn
  log_retention_days = var.log_retention_days

  depends_on = [aws_secretsmanager_secret_version.db]
}

# Create the schema once on the writer; storage-level replication carries it
# to the DR region.
resource "aws_lambda_invocation" "migrate" {
  provider = aws.primary

  function_name = module.app_primary.function_name
  input         = jsonencode({ action = "migrate" })

  depends_on = [aws_rds_cluster_instance.primary, aws_secretsmanager_secret_version.db]
}

# --- Route 53: health checks + failover records ------------------------------
# Each region's /health returns 200 only if that region can commit a write
# (Lambda up AND local Aurora cluster is the writer AND DynamoDB reachable).
# DNS therefore follows the Aurora writer: after failover the old primary
# stays unhealthy until a deliberate failback, so DNS cannot flap back onto a
# read-only database when the fault clears.

resource "aws_route53_health_check" "region" {
  provider = aws.primary
  for_each = {
    primary   = module.app_primary.default_endpoint_host
    secondary = module.app_secondary.default_endpoint_host
  }

  fqdn              = each.value
  type              = "HTTPS"
  port              = 443
  resource_path     = "/health"
  request_interval  = 10
  failure_threshold = 3
  enable_sni        = true

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_route53_record" "api" {
  provider = aws.primary
  for_each = {
    primary = {
      failover = "PRIMARY"
      target   = module.app_primary.domain_target
      zone_id  = module.app_primary.domain_zone_id
    }
    secondary = {
      failover = "SECONDARY"
      target   = module.app_secondary.domain_target
      zone_id  = module.app_secondary.domain_zone_id
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = local.api_fqdn
  type            = "A"
  set_identifier  = each.key
  health_check_id = aws_route53_health_check.region[each.key].id

  failover_routing_policy {
    type = each.value.failover
  }

  alias {
    name                   = each.value.target
    zone_id                = each.value.zone_id
    evaluate_target_health = false
  }
}
