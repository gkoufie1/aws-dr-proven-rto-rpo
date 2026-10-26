# The drill: a scheduled, self-grading chaos experiment.
#
#   preflight -> [ prober: 1 write/s through the public failover hostname ] -> analyze -> stop fault -> (failback)
#                [ wait 60 s baseline -> start FIS -> wait for runbook      ]
#
# The drill never performs the failover itself; it only breaks the primary and
# watches. If the watchdog + runbook don't recover the service, the drill
# records a FAIL - which is the point.

# --- Evidence bucket ---------------------------------------------------------

resource "aws_s3_bucket" "evidence" {
  provider = aws.secondary

  bucket        = "${local.name}-evidence-${local.account_id}"
  force_destroy = true # the durable record is the git history (evidence/), not this bucket
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  provider = aws.secondary

  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "evidence" {
  provider = aws.secondary

  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  provider = aws.secondary

  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.secondary.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  provider = aws.secondary

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
  provider = aws.secondary

  bucket = aws_s3_bucket.evidence.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- Prober ------------------------------------------------------------------

data "aws_iam_policy_document" "prober" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/drills/*"]
  }

  statement {
    actions   = ["kms:GenerateDataKey", "kms:Encrypt"]
    resources = [aws_kms_key.secondary.arn]
  }
}

module "prober" {
  source    = "./modules/lambda-fn"
  providers = { aws = aws.secondary }

  name               = "${local.name}-prober"
  description        = "Synthetic client: one acknowledged write per second through the failover hostname"
  package_path       = data.archive_file.fn["prober"].output_path
  package_hash       = data.archive_file.fn["prober"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.prober.json
  timeout            = 900
  memory_size        = 256
  log_retention_days = var.log_retention_days

  environment = {
    API_URL         = "https://${local.api_fqdn}"
    EVIDENCE_BUCKET = aws_s3_bucket.evidence.bucket
  }
}

# --- Analyzer ----------------------------------------------------------------

data "aws_iam_policy_document" "analyzer" {
  statement {
    sid       = "Evidence"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/drills/*"]
  }

  statement {
    sid       = "Keys"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt"]
    resources = [aws_kms_key.secondary.arn]
  }

  statement {
    sid       = "Timeline"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.dr_state.arn]
  }

  statement {
    sid       = "SurvivingWritesLedger"
    actions   = ["dynamodb:Query"]
    resources = [local.ledger_arn_secondary]
  }

  statement {
    sid       = "SurvivingWritesAurora"
    actions   = ["rds-data:ExecuteStatement"]
    resources = [aws_rds_cluster.secondary.arn]
  }

  statement {
    sid       = "DbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_secret_arn_secondary]
  }

  statement {
    sid       = "ReplicationLagMetrics"
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"]
  }

  statement {
    sid       = "ExperimentTimeline"
    actions   = ["fis:GetExperiment"]
    resources = ["arn:${local.partition}:fis:${var.primary_region}:${local.account_id}:experiment/*"]
  }
}

module "analyzer" {
  source    = "./modules/lambda-fn"
  providers = { aws = aws.secondary }

  name               = "${local.name}-analyzer"
  description        = "Computes measured RTO/RPO from probe samples, runbook timestamps and surviving data"
  package_path       = data.archive_file.fn["analyzer"].output_path
  package_hash       = data.archive_file.fn["analyzer"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.analyzer.json
  timeout            = 120
  memory_size        = 512
  log_retention_days = var.log_retention_days

  environment = {
    EVIDENCE_BUCKET      = aws_s3_bucket.evidence.bucket
    STATE_TABLE          = aws_dynamodb_table.dr_state.name
    DB_CLUSTER_ARN       = aws_rds_cluster.secondary.arn
    DB_SECRET_ARN        = local.db_secret_arn_secondary
    DB_NAME              = local.db_name
    PRIMARY_REGION       = var.primary_region
    SECONDARY_REGION     = var.secondary_region
    SECONDARY_CLUSTER_ID = aws_rds_cluster.secondary.cluster_identifier
    LEDGER_TABLE_NAME    = aws_dynamodb_table.ledger.name
    RTO_TARGET_SECONDS   = tostring(var.rto_target_seconds)
    RPO_TARGET_SECONDS   = tostring(var.rpo_target_seconds)
    FAULT_DESCRIPTION    = aws_fis_experiment_template.region_impairment.description
  }
}

# --- Drill state machine -----------------------------------------------------

resource "aws_iam_role" "drill" {
  provider = aws.secondary

  name               = "${local.name}-drill"
  assume_role_policy = data.aws_iam_policy_document.assume_states.json
}

data "aws_iam_policy_document" "drill" {
  source_policy_documents = [data.aws_iam_policy_document.states_observability.json]

  statement {
    sid       = "Functions"
    actions   = ["lambda:InvokeFunction"]
    resources = [module.prober.arn, module.analyzer.arn, module.drill_control.arn]
  }

  statement {
    sid       = "ReadDrState"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.dr_state.arn]
  }

  statement {
    sid       = "ReadDrStateKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secondary.arn]
  }

  statement {
    sid       = "StartFailback"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.failback.arn]
  }

  statement {
    sid       = "TrackFailback"
    actions   = ["states:DescribeExecution", "states:StopExecution"]
    resources = ["arn:${local.partition}:states:${var.secondary_region}:${local.account_id}:execution:${aws_sfn_state_machine.failback.name}:*"]
  }

  statement {
    sid       = "SyncIntegrationRule"
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["arn:${local.partition}:events:${var.secondary_region}:${local.account_id}:rule/StepFunctionsGetEventsForStepFunctionsExecutionRule"]
  }
}

resource "aws_iam_role_policy" "drill" {
  provider = aws.secondary

  name   = "drill"
  role   = aws_iam_role.drill.id
  policy = data.aws_iam_policy_document.drill.json
}

locals {
  drill_definition = {
    Comment       = "Region-impairment DR drill for ${local.name}: inject fault, measure, grade"
    QueryLanguage = "JSONata"
    StartAt       = "Init"
    States = {
      Init = {
        Type = "Pass"
        Assign = {
          runId     = "{% $states.context.Execution.Name %}"
          failback  = "{% $exists($states.input.failback) ? $states.input.failback : true %}"
          startedAt = "{% $states.context.Execution.StartTime %}"
          # Pre-declared so every path that reads them is statically valid.
          failbackStatus = "SKIPPED"
          drillError     = "none"
        }
        Next = "ReadDrState"
      }

      ReadDrState = {
        Type      = "Task"
        Resource  = "arn:aws:states:::dynamodb:getItem"
        Arguments = { TableName = aws_dynamodb_table.dr_state.name, Key = local.state_key, ConsistentRead = true }
        Assign    = { drState = "{% $states.result.Item.state.S %}" }
        Next      = "SteadyState"
      }

      SteadyState = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $drState = 'PRIMARY_ACTIVE' %}", Next = "CheckPrimaryHealth" }]
        Default = "NotSteadyState"
      }

      NotSteadyState = {
        Type  = "Fail"
        Error = "NotSteadyState"
        Cause = "{% 'Refusing to drill: DR state is ' & $drState & ' (expected PRIMARY_ACTIVE)' %}"
      }

      CheckPrimaryHealth = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.drill_control.arn
          Payload      = { action = "check_health", url = local.primary_health_url }
        }
        Assign = { primaryHealthy = "{% $states.result.Payload.healthy %}" }
        Retry  = local.sfn_retry_transient
        Next   = "PrimaryHealthy"
      }

      PrimaryHealthy = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $primaryHealthy = true %}", Next = "RunDrill" }]
        Default = "PrimaryNotHealthy"
      }

      PrimaryNotHealthy = {
        Type  = "Fail"
        Error = "PrimaryNotHealthy"
        Cause = "Refusing to drill: the primary region is not healthy before fault injection"
      }

      RunDrill = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "Probe"
            States = {
              Probe = {
                Type           = "Task"
                Resource       = "arn:aws:states:::lambda:invoke"
                TimeoutSeconds = 900
                Arguments = {
                  FunctionName = module.prober.arn
                  Payload = {
                    run_id                     = "{% $runId %}"
                    max_seconds                = 840
                    no_fault_timeout_seconds   = 420
                    recovery_success_threshold = 30
                  }
                }
                Output = "{% $states.result.Payload %}"
                End    = true
              }
            }
          },
          {
            StartAt = "Baseline"
            States = {
              Baseline = {
                Type    = "Wait"
                Seconds = 60
                Next    = "InjectFault"
              }
              InjectFault = {
                Type     = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Arguments = {
                  FunctionName = module.drill_control.arn
                  Payload      = { action = "start_experiment", run_id = "{% $runId %}" }
                }
                Assign = {
                  experimentId = "{% $states.result.Payload.experiment_id %}"
                  polls        = 0
                }
                Next = "WaitForRunbook"
              }
              WaitForRunbook = {
                Type    = "Wait"
                Seconds = 15
                Next    = "PollDrState"
              }
              PollDrState = {
                Type      = "Task"
                Resource  = "arn:aws:states:::dynamodb:getItem"
                Arguments = { TableName = aws_dynamodb_table.dr_state.name, Key = local.state_key, ConsistentRead = true }
                Assign = {
                  runbookState = "{% $states.result.Item.state.S %}"
                  polls        = "{% $polls + 1 %}"
                }
                Retry = local.sfn_retry_transient
                Next  = "RunbookFinished"
              }
              RunbookFinished = {
                Type = "Choice"
                Choices = [{
                  Condition = "{% $runbookState in ['SECONDARY_ACTIVE', 'FAILOVER_FAILED'] or $polls >= 56 %}"
                  Next      = "ChaosDone"
                }]
                Default = "WaitForRunbook"
              }
              ChaosDone = {
                Type   = "Pass"
                Output = { experiment_id = "{% $experimentId %}", dr_state = "{% $runbookState %}" }
                End    = true
              }
            }
          },
        ]
        Assign = {
          probe = "{% $states.result[0] %}"
          chaos = "{% $states.result[1] %}"
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Assign      = { drillError = "{% $string($states.errorOutput) %}" }
          Next        = "AbortStopFault"
        }]
        Next = "Analyze"
      }

      Analyze = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.analyzer.arn
          Payload = {
            run_id        = "{% $runId %}"
            started_at    = "{% $startedAt %}"
            probe         = "{% $probe %}"
            experiment_id = "{% $chaos.experiment_id %}"
            dr_state      = "{% $chaos.dr_state %}"
          }
        }
        Assign = { result = "{% $states.result.Payload %}" }
        Retry  = local.sfn_retry_transient
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Assign      = { drillError = "{% $string($states.errorOutput) %}" }
          Next        = "AbortStopFault"
        }]
        Next = "StopFault"
      }

      # Measurement is done; end the impairment now rather than waiting out
      # the full fault duration (restores the primary Lambda + replication).
      StopFault = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.drill_control.arn
          Payload      = { action = "stop_experiments", run_id = "{% $runId %}" }
        }
        Retry = local.sfn_retry_transient
        Next  = "ShouldFailBack"
      }

      ShouldFailBack = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $failback = true and $chaos.dr_state = 'SECONDARY_ACTIVE' %}"
          Next      = "FailBack"
        }]
        Default = "Finish"
      }

      FailBack = {
        Type     = "Task"
        Resource = "arn:aws:states:::states:startExecution.sync:2"
        Arguments = {
          StateMachineArn = aws_sfn_state_machine.failback.arn
          Name            = "{% $runId & '-failback' %}"
          Input           = { reason = "{% 'drill ' & $runId %}" }
        }
        Assign = { failbackStatus = "SUCCEEDED" }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Assign      = { failbackStatus = "FAILED" }
          Next        = "Finish"
        }]
        Next = "Finish"
      }

      Finish = {
        Type = "Succeed"
        Output = {
          run_id       = "{% $runId %}"
          verdict      = "{% $result.verdict %}"
          evidence_key = "{% $result.evidence_key %}"
          rto_seconds  = "{% $result.rto_seconds %}"
          rpo_seconds  = "{% $result.rpo_seconds %}"
          failback     = "{% $failbackStatus %}"
        }
      }

      AbortStopFault = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.drill_control.arn
          Payload      = { action = "stop_experiments", run_id = "{% $runId %}" }
        }
        Retry = local.sfn_retry_transient
        Next  = "DrillErrored"
      }

      DrillErrored = {
        Type  = "Fail"
        Error = "DrillErrored"
        Cause = "{% $drillError %}"
      }
    }
  }
}

resource "aws_sfn_state_machine" "drill" {
  provider = aws.secondary

  name       = "${local.name}-drill"
  role_arn   = aws_iam_role.drill.arn
  definition = jsonencode(local.drill_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.states["drill"].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.drill]
}

resource "aws_scheduler_schedule" "drill" {
  provider = aws.secondary

  name                = "${local.name}-drill"
  description         = "Recurring DR drill for long-lived stacks (GitHub Actions drives ephemeral ones)."
  schedule_expression = var.drill_schedule_expression
  state               = var.drill_schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.drill.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ failback = true })
  }
}

# --- TLS-only access for both buckets ---------------------------------------

data "aws_iam_policy_document" "tls_only" {
  for_each = {
    evidence   = aws_s3_bucket.evidence.arn
    fis_config = aws_s3_bucket.fis_config.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value, "${each.value}/*"]
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
  provider = aws.secondary

  bucket     = aws_s3_bucket.evidence.id
  policy     = data.aws_iam_policy_document.tls_only["evidence"].json
  depends_on = [aws_s3_bucket_public_access_block.evidence]
}

resource "aws_s3_bucket_policy" "fis_config" {
  provider = aws.primary

  bucket     = aws_s3_bucket.fis_config.id
  policy     = data.aws_iam_policy_document.tls_only["fis_config"].json
  depends_on = [aws_s3_bucket_public_access_block.fis_config]
}
