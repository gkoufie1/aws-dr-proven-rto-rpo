# AWS FIS "region impairment" experiment, run in the primary region:
#   1. every invocation of the primary API Lambda returns an error
#      (aws:lambda:invocation-error via the FIS Lambda extension), and
#   2. optionally, DynamoDB global-table replication out of the primary is
#      severed, so in-flight writes are genuinely at risk.
# Nothing in the experiment touches the failover path - detection, promotion
# and DNS are left entirely to the automation under test.

# --- Fault configuration bucket (FIS writes, the Lambda extension polls) ----

resource "aws_s3_bucket" "fis_config" {
  provider = aws.primary

  bucket        = "${local.name}-fis-config-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "fis_config" {
  provider = aws.primary

  bucket                  = aws_s3_bucket.fis_config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fis_config" {
  provider = aws.primary

  bucket = aws_s3_bucket.fis_config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Fault configs are only meaningful while an experiment runs.
resource "aws_s3_bucket_lifecycle_configuration" "fis_config" {
  provider = aws.primary

  bucket = aws_s3_bucket.fis_config.id
  rule {
    id     = "expire-stale-fault-configs"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "fis_config" {
  provider = aws.primary

  bucket = aws_s3_bucket.fis_config.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- Experiment role ---------------------------------------------------------

data "aws_iam_policy_document" "assume_fis" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "fis" {
  provider = aws.primary

  name               = "${local.name}-fis-experiment"
  assume_role_policy = data.aws_iam_policy_document.assume_fis.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    sid       = "WriteFaultConfig"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.fis_config.arn}/FisConfigs/*"]
  }

  statement {
    sid       = "InspectTargetFunction"
    actions   = ["lambda:GetFunction"]
    resources = [module.app_primary.function_arn, "${module.app_primary.function_arn}:*"]
  }

  statement {
    sid       = "ResolveTargets"
    actions   = ["tag:GetResources"] # not resource-scopable
    resources = ["*"]
  }

  statement {
    sid = "PauseGlobalTableReplication"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetResourcePolicy",
      "dynamodb:PutResourcePolicy",
      "dynamodb:DeleteResourcePolicy",
    ]
    resources = [
      aws_dynamodb_table.ledger.arn,
      "${aws_dynamodb_table.ledger.arn}/stream/*",
    ]
  }

  statement {
    sid = "ExperimentLogging"
    actions = [
      "logs:CreateLogDelivery",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis" {
  provider = aws.primary

  name   = "fis-experiment"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_cloudwatch_log_group" "fis" {
  provider = aws.primary

  name              = "/aws/fis/${local.name}"
  retention_in_days = var.log_retention_days
}

# --- Stop condition: abort if NO region has been healthy for 15 minutes -----
# The DR region is unhealthy by design in steady state (no writer), so the
# guardrail is "primary + secondary health < 1 for 15 consecutive minutes":
# failover has clearly not worked, so stop hurting the primary.
# Route 53 health-check metrics only exist in us-east-1.

resource "aws_cloudwatch_metric_alarm" "no_healthy_region" {
  provider = aws.primary

  alarm_name          = "${local.name}-no-healthy-region"
  alarm_description   = "FIS stop condition: neither region passed health checks for 15 minutes."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "any_healthy"
    expression  = "p + s"
    label       = "Healthy regions"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = { p = "primary", s = "secondary" }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/Route53"
        metric_name = "HealthCheckStatus"
        period      = 60
        stat        = "Minimum"
        dimensions = {
          HealthCheckId = aws_route53_health_check.region[metric_query.value].id
        }
      }
    }
  }
}

# --- Experiment template -----------------------------------------------------

resource "aws_fis_experiment_template" "region_impairment" {
  provider = aws.primary

  description = "Impair the primary region: API Lambda fails every invocation${var.pause_dynamodb_replication ? " and DynamoDB replication is severed" : ""}."
  role_arn    = aws_iam_role.fis.arn

  action {
    name        = "fail-primary-api"
    action_id   = "aws:lambda:invocation-error"
    description = "Every primary API invocation returns an error without running handler code."

    parameter {
      key   = "duration"
      value = var.fault_duration
    }
    parameter {
      key   = "invocationPercentage"
      value = "100"
    }
    parameter {
      key   = "preventExecution"
      value = "true"
    }

    target {
      key   = "Functions"
      value = "primary-api"
    }
  }

  dynamic "action" {
    for_each = var.pause_dynamodb_replication ? [1] : []
    content {
      name        = "sever-ledger-replication"
      action_id   = "aws:dynamodb:global-table-pause-replication"
      description = "Stop replication out of the primary replica (may lag up to 5 min to take full effect)."

      parameter {
        key   = "duration"
        value = var.fault_duration
      }

      target {
        key   = "Tables"
        value = "ledger"
      }
    }
  }

  target {
    name           = "primary-api"
    resource_type  = "aws:lambda:function"
    selection_mode = "ALL"
    resource_arns  = [module.app_primary.function_arn]
  }

  dynamic "target" {
    for_each = var.pause_dynamodb_replication ? [1] : []
    content {
      name           = "ledger"
      resource_type  = "aws:dynamodb:global-table"
      selection_mode = "ALL"
      resource_arns  = [aws_dynamodb_table.ledger.arn]
    }
  }

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.no_healthy_region.arn
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "fail"
  }

  tags = { Name = "${local.name}-region-impairment" }
}
