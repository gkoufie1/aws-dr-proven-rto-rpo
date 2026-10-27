# --- Lambda packages ---------------------------------------------------------
# scripts/build.sh assembles each function (code + shared DSQL helper + the
# pure-Python Postgres driver) under ../build/<fn>/ before plan or apply.

locals {
  functions = toset(["app", "migrate", "prober", "analyzer"])
}

data "archive_file" "fn" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${path.module}/../build/${each.key}"
  output_path = "${path.module}/../build/${each.key}.zip"
  # Keep *.dist-info: scramp (pg8000 dependency) reads its own package metadata at import.
  excludes = ["__pycache__", "**/__pycache__/**", "*.pyc"]
}

# --- Regional application stacks (identical; both serve traffic) -----------

data "aws_ssm_parameter" "fis_layer_east" {
  provider = aws.east
  name     = "/aws/service/fis/lambda-extension/AWS-FIS-extension-x86_64/1.x.x"
}

module "app_east" {
  source    = "./modules/regional-app"
  providers = { aws = aws.east }

  name               = "${local.name}-east"
  api_fqdn           = local.api_fqdn
  hosted_zone_id     = data.aws_route53_zone.this.zone_id
  package_path       = data.archive_file.fn["app"].output_path
  package_hash       = data.archive_file.fn["app"].output_base64sha256
  dsql_cluster_arn   = aws_dsql_cluster.east.arn
  dsql_endpoint      = local.dsql_endpoint[var.east_region]
  log_retention_days = var.log_retention_days

  # The drill impairs the east region, so only it carries the FIS extension.
  fis_enabled       = true
  fis_layer_arn     = data.aws_ssm_parameter.fis_layer_east.insecure_value
  fis_config_bucket = aws_s3_bucket.fis_config.bucket
}

module "app_west" {
  source    = "./modules/regional-app"
  providers = { aws = aws.west }

  name               = "${local.name}-west"
  api_fqdn           = local.api_fqdn
  hosted_zone_id     = data.aws_route53_zone.this.zone_id
  package_path       = data.archive_file.fn["app"].output_path
  package_hash       = data.archive_file.fn["app"].output_base64sha256
  dsql_cluster_arn   = aws_dsql_cluster.west.arn
  dsql_endpoint      = local.dsql_endpoint[var.west_region]
  log_retention_days = var.log_retention_days
}

# --- Schema + least-privilege database roles ---------------------------------
# The only identity allowed to connect as DSQL `admin`.

data "aws_iam_policy_document" "migrate" {
  statement {
    sid       = "DsqlAdmin"
    actions   = ["dsql:DbConnectAdmin"]
    resources = [aws_dsql_cluster.east.arn, aws_dsql_cluster.west.arn]
  }
}

module "migrate" {
  source    = "../../terraform/modules/lambda-fn"
  providers = { aws = aws.east }

  name               = "${local.name}-migrate"
  description        = "Creates the schema and maps IAM roles onto least-privilege DSQL roles"
  package_path       = data.archive_file.fn["migrate"].output_path
  package_hash       = data.archive_file.fn["migrate"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.migrate.json
  timeout            = 300
  log_retention_days = var.log_retention_days

  environment = {
    ROLE_MAPPINGS = jsonencode({
      app     = [module.app_east.role_arn, module.app_west.role_arn]
      auditor = ["arn:${local.partition}:iam::${local.account_id}:role/${module.analyzer.role_name}"]
    })
  }
}

# Run against the east endpoint, then the west one. The second run should find
# everything already in place - which proves DDL, roles and IAM mappings
# replicated - and is otherwise a safe no-op.
resource "aws_lambda_invocation" "migrate_east" {
  provider = aws.east

  function_name = module.migrate.name
  input = jsonencode({
    endpoint = local.dsql_endpoint[var.east_region]
    region   = var.east_region
  })

  depends_on = [aws_dsql_cluster_peering.east, aws_dsql_cluster_peering.west]
}

resource "aws_lambda_invocation" "migrate_west" {
  provider = aws.east

  function_name = module.migrate.name
  input = jsonencode({
    endpoint = local.dsql_endpoint[var.west_region]
    region   = var.west_region
  })

  depends_on = [aws_lambda_invocation.migrate_east]
}
