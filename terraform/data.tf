# --- Encryption keys (one per region; KMS keys are regional) ----------------

# Explicit policy equal to the AWS default: the account (and therefore IAM
# policies) controls use of the key. Services use grants created on our behalf.
data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_109:Root-account kms:* is the AWS default key policy; access is governed by IAM
  #checkov:skip=CKV_AWS_111:Same - key policies always use Resource "*" (the key itself)
  #checkov:skip=CKV_AWS_356:Same - "*" in a key policy means "this key"
  statement {
    sid       = "AccountControlsKey"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "primary" {
  provider = aws.primary

  description             = "${local.name} data encryption (primary)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_key" "secondary" {
  provider = aws.secondary

  description             = "${local.name} data encryption (secondary)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

# Pre-create the Aurora log-export groups so Terraform owns their retention
# and removes them on destroy (RDS would otherwise create never-expiring ones).
resource "aws_cloudwatch_log_group" "aurora_primary" {
  provider = aws.primary

  name              = "/aws/rds/cluster/${local.name}-primary/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "aurora_secondary" {
  provider = aws.secondary

  name              = "/aws/rds/cluster/${local.name}-secondary/postgresql"
  retention_in_days = var.log_retention_days
}

# --- Database credentials ----------------------------------------------------
# Replicated to the DR region so the Data API can authenticate there even when
# the primary region's Secrets Manager endpoint is unreachable.

resource "random_password" "db" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  provider = aws.primary

  name                    = "${local.name}/aurora-master"
  description             = "Aurora master credentials used by the RDS Data API"
  recovery_window_in_days = 0 # ephemeral lab stack; allows clean destroy/re-apply

  replica {
    region = var.secondary_region
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  provider = aws.primary

  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "drproof_admin"
    password = random_password.db.result
  })
}

# --- Aurora Global Database --------------------------------------------------

resource "aws_rds_global_cluster" "this" {
  provider = aws.primary

  global_cluster_identifier = "${local.name}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  database_name             = local.db_name
  storage_encrypted         = true
  deletion_protection       = false
  force_destroy             = true
}

resource "aws_rds_cluster" "primary" {
  provider = aws.primary

  cluster_identifier        = "${local.name}-primary"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  engine_mode               = "provisioned"
  database_name             = local.db_name

  master_username = jsondecode(aws_secretsmanager_secret_version.db.secret_string)["username"]
  master_password = random_password.db.result

  db_subnet_group_name   = module.network_primary.db_subnet_group_name
  vpc_security_group_ids = [module.network_primary.db_security_group_id]

  enable_http_endpoint                = true
  iam_database_authentication_enabled = true
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.primary.arn
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  backup_retention_period = 1
  copy_tags_to_snapshot   = true
  skip_final_snapshot     = true
  deletion_protection     = false

  # After a drill the writer role has moved; Terraform must not try to "fix" it.
  lifecycle {
    ignore_changes = [global_cluster_identifier, replication_source_identifier]
  }

  depends_on = [aws_cloudwatch_log_group.aurora_primary]
}

resource "aws_rds_cluster_instance" "primary" {
  provider = aws.primary

  identifier                 = "${local.name}-primary-1"
  cluster_identifier         = aws_rds_cluster.primary.id
  engine                     = aws_rds_cluster.primary.engine
  engine_version             = aws_rds_cluster.primary.engine_version
  instance_class             = "db.serverless"
  auto_minor_version_upgrade = false # no effect on global DB members; explicit for clarity

  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # free tier
  performance_insights_kms_key_id       = aws_kms_key.primary.arn
}

resource "aws_rds_cluster" "secondary" {
  provider = aws.secondary

  cluster_identifier        = "${local.name}-secondary"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  engine_mode               = "provisioned"

  db_subnet_group_name   = module.network_secondary.db_subnet_group_name
  vpc_security_group_ids = [module.network_secondary.db_security_group_id]

  # Enabled now; Data API calls fail until this cluster is promoted, which is
  # exactly the signal the DR region's /health endpoint relies on.
  enable_http_endpoint                = true
  iam_database_authentication_enabled = true
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.secondary.arn
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  backup_retention_period = 1
  copy_tags_to_snapshot   = true
  skip_final_snapshot     = true
  deletion_protection     = false

  lifecycle {
    ignore_changes = [global_cluster_identifier, replication_source_identifier]
  }

  depends_on = [aws_rds_cluster_instance.primary, aws_cloudwatch_log_group.aurora_secondary]
}

# A warm reader in the DR region. Without it the promoted cluster would have
# no instance to become writer and RTO would include instance provisioning.
resource "aws_rds_cluster_instance" "secondary" {
  provider = aws.secondary

  identifier                 = "${local.name}-secondary-1"
  cluster_identifier         = aws_rds_cluster.secondary.id
  engine                     = aws_rds_cluster.secondary.engine
  engine_version             = aws_rds_cluster.secondary.engine_version
  instance_class             = "db.serverless"
  auto_minor_version_upgrade = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = aws_kms_key.secondary.arn
}

# --- DynamoDB global table ---------------------------------------------------

resource "aws_dynamodb_table" "ledger" {
  provider = aws.primary

  name         = "${local.name}-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.primary.arn
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  replica {
    region_name            = var.secondary_region
    kms_key_arn            = aws_kms_key.secondary.arn
    point_in_time_recovery = true
    propagate_tags         = true
  }

  tags = {
    DisruptDynamoDb = "Allowed" # opt-in tag used by FIS cross-region scenarios
  }
}
