# AWS FIS "region impairment" experiment for the active-active stack: every
# invocation of the east API Lambda fails (aws:lambda:invocation-error via the
# FIS Lambda extension). Nothing in the experiment touches routing - moving
# clients off the impaired region is left entirely to Route 53 health checks.
#
# FIS has no fault action for DSQL itself, so the database tier is not
# impaired; what this drill proves is that writes accepted by EITHER region
# are durable in BOTH, and that the healthy region absorbs the traffic.

# --- Fault configuration bucket (FIS writes, the Lambda extension polls) ----

resource "aws_s3_bucket" "fis_config" {
  provider = aws.east

  bucket        = "${local.name}-fis-config-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "fis_config" {
  provider = aws.east

  bucket                  = aws_s3_bucket.fis_config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fis_config" {
  provider = aws.east

  bucket = aws_s3_bucket.fis_config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Fault configs are only meaningful while an experiment runs.
resource "aws_s3_bucket_lifecycle_configuration" "fis_config" {
  provider = aws.east

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
  provider = aws.east

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
  provider = aws.east

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
    resources = [module.app_east.function_arn, "${module.app_east.function_arn}:*"]
  }

  statement {
    sid       = "ResolveTargets"
    actions   = ["tag:GetResources"] # not resource-scopable
    resources = ["*"]
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
  provider = aws.east

  name   = "fis-experiment"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_cloudwatch_log_group" "fis" {
  provider = aws.east

  name              = "/aws/fis/${local.name}"
  retention_in_days = var.log_retention_days
}

# --- Stop condition: abort if NO region has been healthy for 5 minutes ------
# In active-active both regions are healthy in steady state; if neither is,
# the drill has broken more than it meant to. Route 53 health-check metrics
# only exist in us-east-1.

resource "aws_cloudwatch_metric_alarm" "no_healthy_region" {
  provider = aws.east

  alarm_name          = "${local.name}-no-healthy-region"
  alarm_description   = "FIS stop condition: neither region passed health checks for 5 minutes."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "any_healthy"
    expression  = "e + w"
    label       = "Healthy regions"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = { e = var.east_region, w = var.west_region }
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

resource "aws_fis_experiment_template" "east_impairment" {
  provider = aws.east

  description = "Impair ${var.east_region}: the API Lambda fails every invocation for ${var.fault_duration}."
  role_arn    = aws_iam_role.fis.arn

  action {
    name        = local.fis_action_name
    action_id   = "aws:lambda:invocation-error"
    description = "Every east API invocation returns an error without running handler code."

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
      value = "east-api"
    }
  }

  target {
    name           = "east-api"
    resource_type  = "aws:lambda:function"
    selection_mode = "ALL"
    resource_arns  = [module.app_east.function_arn]
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

  tags = { Name = "${local.name}-east-impairment" }
}
