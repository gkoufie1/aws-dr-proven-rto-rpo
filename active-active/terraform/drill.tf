# The drill, driven by scripts/run-drill.sh:
#
#   [ east client (us-east-2): 1 write/s through the public hostname ]
#   [ west client (us-west-2): 1 write/s through the public hostname ]  -> analyze
#   [ 60 s baseline -> FIS impairs us-east-1 for 5 min -> recovery    ]
#
# Nothing here performs a failover. The drill only breaks a region and
# watches what clients experience; Route 53 is the only recovery mechanism.

# --- Evidence bucket ---------------------------------------------------------

resource "aws_s3_bucket" "evidence" {
  provider = aws.west

  bucket        = "${local.name}-evidence-${local.account_id}"
  force_destroy = true # the durable record is the git history (evidence/), not this bucket
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  provider = aws.west

  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "evidence" {
  provider = aws.west

  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  provider = aws.west

  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  provider = aws.west

  bucket = aws_s3_bucket.evidence.id
  rule {
    id     = "tidy-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "evidence" {
  provider = aws.west

  bucket = aws_s3_bucket.evidence.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "evidence_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.evidence.arn, "${aws_s3_bucket.evidence.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "evidence" {
  provider = aws.west

  bucket = aws_s3_bucket.evidence.id
  policy = data.aws_iam_policy_document.evidence_tls_only.json
}

# --- Synthetic clients -------------------------------------------------------

data "aws_iam_policy_document" "prober" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/drills/*"]
  }
}

module "prober_east" {
  source    = "../../terraform/modules/lambda-fn"
  providers = { aws = aws.witness }

  name               = "${local.name}-client-east"
  description        = "East-side synthetic client (runs in ${var.witness_region}, routed to ${var.east_region})"
  package_path       = data.archive_file.fn["prober"].output_path
  package_hash       = data.archive_file.fn["prober"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.prober.json
  timeout            = 900
  log_retention_days = var.log_retention_days

  environment = {
    API_URL          = "https://${local.api_fqdn}"
    EVIDENCE_BUCKET  = aws_s3_bucket.evidence.bucket
    CLIENT_NAME      = "east"
    METRIC_NAMESPACE = local.metric_namespace
  }
}

module "prober_west" {
  source    = "../../terraform/modules/lambda-fn"
  providers = { aws = aws.west }

  name               = "${local.name}-client-west"
  description        = "West-side synthetic client (runs in and is routed to ${var.west_region})"
  package_path       = data.archive_file.fn["prober"].output_path
  package_hash       = data.archive_file.fn["prober"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.prober.json
  timeout            = 900
  log_retention_days = var.log_retention_days

  environment = {
    API_URL          = "https://${local.api_fqdn}"
    EVIDENCE_BUCKET  = aws_s3_bucket.evidence.bucket
    CLIENT_NAME      = "west"
    METRIC_NAMESPACE = local.metric_namespace
  }
}

# --- Analyzer ----------------------------------------------------------------

data "aws_iam_policy_document" "analyzer" {
  statement {
    sid       = "Evidence"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/drills/*"]
  }

  # Read-back as the `auditor` database role (SELECT only) in BOTH regions.
  statement {
    sid       = "DsqlReadBack"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.east.arn, aws_dsql_cluster.west.arn]
  }

  statement {
    sid       = "ExperimentTimeline"
    actions   = ["fis:GetExperiment"]
    resources = ["arn:${local.partition}:fis:${var.east_region}:${local.account_id}:experiment/*"]
  }
}

module "analyzer" {
  source    = "../../terraform/modules/lambda-fn"
  providers = { aws = aws.west }

  name               = "${local.name}-analyzer"
  description        = "Grades an active-active drill from client samples, FIS timings and read-back from both regions"
  package_path       = data.archive_file.fn["analyzer"].output_path
  package_hash       = data.archive_file.fn["analyzer"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.analyzer.json
  timeout            = 120
  memory_size        = 512
  log_retention_days = var.log_retention_days

  environment = {
    EVIDENCE_BUCKET           = aws_s3_bucket.evidence.bucket
    IMPAIRED_REGION           = var.east_region
    FIS_ACTION_NAME           = local.fis_action_name
    DSQL_ENDPOINTS            = jsonencode(local.dsql_endpoint)
    MAX_OUTAGE_TARGET_SECONDS = tostring(var.max_outage_target_seconds)
    FAULT_DESCRIPTION         = aws_fis_experiment_template.east_impairment.description
  }
}
