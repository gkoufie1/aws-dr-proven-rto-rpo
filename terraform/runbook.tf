# Everything in this file lives in the SECONDARY region. A failover runbook
# that runs in the region it is meant to rescue is not a runbook.
#
# Detection deliberately avoids us-east-1 control-plane dependencies:
# Route 53 health-check metrics/alarms only exist in us-east-1, so alarm-driven
# automation would fail exactly when us-east-1 is the region in trouble.
# Instead, a watchdog in the DR region probes the primary directly.

# --- DR state / failover lock ------------------------------------------------

resource "aws_dynamodb_table" "dr_state" {
  provider = aws.secondary

  name         = "${local.name}-dr-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.secondary.arn
  }
}

# Single item acting as a state machine + mutex:
# PRIMARY_ACTIVE -> FAILING_OVER -> SECONDARY_ACTIVE -> FAILING_BACK -> PRIMARY_ACTIVE
# FAILOVER_FAILED / FAILBACK_FAILED require a human (see docs/runbook.md).
resource "aws_dynamodb_table_item" "failover_state" {
  provider = aws.secondary

  table_name = aws_dynamodb_table.dr_state.name
  hash_key   = aws_dynamodb_table.dr_state.hash_key
  item = jsonencode({
    pk    = { S = "failover" }
    state = { S = "PRIMARY_ACTIVE" }
  })

  lifecycle {
    ignore_changes = [item] # owned by the runbooks after creation
  }
}

# --- Notifications -----------------------------------------------------------

resource "aws_sns_topic" "dr_events" {
  provider = aws.secondary

  name              = "${local.name}-dr-events"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  provider = aws.secondary
  count    = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.dr_events.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- drill_control: cross-region helper (FIS + external health checks) ------

data "aws_iam_policy_document" "drill_control" {
  statement {
    sid       = "StartFromTemplate"
    actions   = ["fis:StartExperiment"]
    resources = ["arn:${local.partition}:fis:${var.primary_region}:${local.account_id}:experiment-template/${aws_fis_experiment_template.region_impairment.id}"]
  }

  statement {
    sid = "ManageExperiments"
    actions = [
      "fis:StartExperiment",
      "fis:GetExperiment",
      "fis:StopExperiment",
      "fis:TagResource",
    ]
    resources = ["arn:${local.partition}:fis:${var.primary_region}:${local.account_id}:experiment/*"]
  }

  statement {
    sid       = "ListExperiments"
    actions   = ["fis:ListExperiments"]
    resources = ["*"]
  }

  # The first StartExperiment in an account creates FIS's service-linked
  # role. Without this the first drill in a fresh account fails with
  # AccessDenied on iam:CreateServiceLinkedRole (found on the first real run).
  statement {
    sid       = "CreateFisServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/fis.amazonaws.com/AWSServiceRoleForFIS"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["fis.amazonaws.com"]
    }
  }
}

module "drill_control" {
  source    = "./modules/lambda-fn"
  providers = { aws = aws.secondary }

  name               = "${local.name}-drill-control"
  description        = "Cross-region helper: start/stop FIS experiments, probe health endpoints from outside"
  package_path       = data.archive_file.fn["drill_control"].output_path
  package_hash       = data.archive_file.fn["drill_control"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.drill_control.json
  timeout            = 30
  log_retention_days = var.log_retention_days

  environment = {
    PRIMARY_REGION  = var.primary_region
    FIS_TEMPLATE_ID = aws_fis_experiment_template.region_impairment.id
  }
}

# --- Watchdog ----------------------------------------------------------------

data "aws_iam_policy_document" "watchdog" {
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.dr_state.arn]
  }

  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.failover.arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secondary.arn]
  }
}

module "watchdog" {
  source    = "./modules/lambda-fn"
  providers = { aws = aws.secondary }

  name               = "${local.name}-watchdog"
  description        = "Probes the primary region every 5 s and starts the failover runbook on sustained failure"
  package_path       = data.archive_file.fn["watchdog"].output_path
  package_hash       = data.archive_file.fn["watchdog"].output_base64sha256
  policy_json        = data.aws_iam_policy_document.watchdog.json
  timeout            = 60
  memory_size        = 128
  log_retention_days = var.log_retention_days

  environment = {
    STATE_TABLE                = aws_dynamodb_table.dr_state.name
    FAILOVER_STATE_MACHINE_ARN = aws_sfn_state_machine.failover.arn
    PRIMARY_HEALTH_URL         = local.primary_health_url
    FAILURE_THRESHOLD          = tostring(var.watchdog_failure_threshold)
    PROBE_INTERVAL_SECONDS     = "5"
    RUN_SECONDS                = "50"
  }
}

data "aws_iam_policy_document" "assume_scheduler" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  provider = aws.secondary

  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.assume_scheduler.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [module.watchdog.arn]
  }

  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.drill.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  provider = aws.secondary

  name   = "scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "watchdog" {
  provider = aws.secondary

  name                = "${local.name}-watchdog"
  description         = "Each invocation probes for ~50 s, so detection is continuous."
  schedule_expression = "rate(1 minute)"
  state               = var.auto_failover_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = module.watchdog.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0 # next minute's run is the retry
    }
  }

  # Arm the watchdog only once the primary can actually serve (instance up,
  # schema migrated) and the DR reader exists to fail over to. Otherwise a
  # fresh `apply` would see a 503 from the primary and fail over a new stack.
  depends_on = [
    aws_lambda_invocation.migrate,
    aws_rds_cluster_instance.secondary,
    aws_dynamodb_table_item.failover_state,
  ]
}

# --- Step Functions shared plumbing -----------------------------------------

data "aws_iam_policy_document" "assume_states" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "states_observability" {
  statement {
    sid = "VendedLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_cloudwatch_log_group" "states" {
  provider = aws.secondary
  for_each = toset(["failover", "failback", "drill"])

  name              = "/aws/vendedlogs/states/${local.name}-${each.key}"
  retention_in_days = var.log_retention_days
}

# --- Runbook role (failover + failback) -------------------------------------

resource "aws_iam_role" "runbook" {
  provider = aws.secondary

  name               = "${local.name}-runbook"
  assume_role_policy = data.aws_iam_policy_document.assume_states.json
}

data "aws_iam_policy_document" "runbook" {
  source_policy_documents = [data.aws_iam_policy_document.states_observability.json]

  statement {
    sid       = "DrState"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.dr_state.arn]
  }

  statement {
    sid       = "DrStateKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.secondary.arn]
  }

  statement {
    sid       = "DescribeGlobalDb"
    actions   = ["rds:DescribeGlobalClusters"]
    resources = [local.global_cluster_arn]
  }

  statement {
    sid     = "MoveWriter"
    actions = ["rds:FailoverGlobalCluster", "rds:SwitchoverGlobalCluster"]
    resources = [
      local.global_cluster_arn,
      aws_rds_cluster.primary.arn,
      aws_rds_cluster.secondary.arn,
    ]
  }

  statement {
    sid       = "VerifyFromOutside"
    actions   = ["lambda:InvokeFunction"]
    resources = [module.drill_control.arn]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.dr_events.arn]
  }
}

resource "aws_iam_role_policy" "runbook" {
  provider = aws.secondary

  name   = "runbook"
  role   = aws_iam_role.runbook.id
  policy = data.aws_iam_policy_document.runbook.json
}

# --- Failover runbook --------------------------------------------------------
# Written in JSONata. Each state does one thing and records a timestamp, so
# the drill analyzer can break RTO down into detection / promotion /
# verification / DNS.

locals {
  state_key = { pk = { S = "failover" } }

  sfn_fail_catch = [{
    ErrorEquals = ["States.ALL"]
    Assign      = { errorInfo = "{% $string($states.errorOutput) %}" }
    Next        = "RecordFailure"
  }]

  sfn_retry_transient = [{
    ErrorEquals     = ["States.ALL"]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2
  }]

  # Step Functions SDK integrations return Java-SDK field names: "DbClusterArn",
  # not boto3/CLI "DBClusterArn". Getting this wrong never matches the writer
  # (found on the first real drill: promotion succeeded, runbook kept polling).
  writer_expr = "{% ($w := $states.result.GlobalClusters[0].GlobalClusterMembers[IsWriter = true].DbClusterArn; $exists($w) ? $w : 'none') %}"

  failover_definition = {
    Comment       = "Unplanned cross-region failover of ${local.name} to ${var.secondary_region}"
    QueryLanguage = "JSONata"
    StartAt       = "Init"
    States = {
      Init = {
        Type = "Pass"
        Assign = {
          reason           = "{% $exists($states.input.reason) ? $states.input.reason : 'manual' %}"
          detectedAt       = "{% $exists($states.input.detected_at) ? $states.input.detected_at : $states.context.Execution.StartTime %}"
          firstFailureAt   = "{% $exists($states.input.first_failure_at) ? $states.input.first_failure_at : $states.context.Execution.StartTime %}"
          failoverIssuedAt = "n/a"
          promotePolls     = 0
          verifyPolls      = 0
          errorInfo        = "none"
        }
        Next = "AcquireLock"
      }

      # Mutex: only one failover may ever be in flight, and only from steady state.
      AcquireLock = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          ConditionExpression      = "#s = :expected"
          UpdateExpression         = "SET #s = :s, trigger_reason = :r, first_failure_at = :f, detected_at = :d, failover_started_at = :t, execution_id = :e REMOVE failover_issued_at, promoted_at, verified_at, last_error"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":expected" = { S = "PRIMARY_ACTIVE" }
            ":s"        = { S = "FAILING_OVER" }
            ":r"        = { S = "{% $reason %}" }
            ":f"        = { S = "{% $firstFailureAt %}" }
            ":d"        = { S = "{% $detectedAt %}" }
            ":t"        = { S = "{% $states.context.State.EnteredTime %}" }
            ":e"        = { S = "{% $states.context.Execution.Id %}" }
          }
        }
        Catch = [{
          ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"]
          Next        = "AlreadyHandled"
        }]
        Next = "DescribeGlobalCluster"
      }

      DescribeGlobalCluster = {
        Type      = "Task"
        Resource  = "arn:aws:states:::aws-sdk:rds:describeGlobalClusters"
        Arguments = { GlobalClusterIdentifier = aws_rds_global_cluster.this.id }
        Assign    = { writerArn = local.writer_expr }
        Retry     = local.sfn_retry_transient
        Catch     = local.sfn_fail_catch
        Next      = "SecondaryAlreadyWriter"
      }

      SecondaryAlreadyWriter = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $writerArn = '${aws_rds_cluster.secondary.arn}' %}"
          Next      = "RecordPromoted"
        }]
        Default = "FailoverGlobalCluster"
      }

      # AllowDataLoss = unplanned failover: we assume the primary is gone and do
      # not wait for it. Any un-replicated writes are what the drill's RPO
      # check is designed to catch.
      FailoverGlobalCluster = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:rds:failoverGlobalCluster"
        Arguments = {
          GlobalClusterIdentifier   = aws_rds_global_cluster.this.id
          TargetDbClusterIdentifier = aws_rds_cluster.secondary.arn
          AllowDataLoss             = true
        }
        Assign = { failoverIssuedAt = "{% $states.context.State.EnteredTime %}" }
        Catch  = local.sfn_fail_catch
        Next   = "WaitForPromotion"
      }

      WaitForPromotion = {
        Type    = "Wait"
        Seconds = 10
        Next    = "CheckPromotion"
      }

      CheckPromotion = {
        Type      = "Task"
        Resource  = "arn:aws:states:::aws-sdk:rds:describeGlobalClusters"
        Arguments = { GlobalClusterIdentifier = aws_rds_global_cluster.this.id }
        Assign = {
          writerArn    = local.writer_expr
          promotePolls = "{% $promotePolls + 1 %}"
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "Promoted"
      }

      Promoted = {
        Type = "Choice"
        Choices = [
          {
            Condition = "{% $writerArn = '${aws_rds_cluster.secondary.arn}' %}"
            Next      = "RecordPromoted"
          },
          {
            Condition = "{% $promotePolls >= 90 %}"
            Next      = "PromotionTimedOut"
          },
        ]
        Default = "WaitForPromotion"
      }

      PromotionTimedOut = {
        Type   = "Pass"
        Assign = { errorInfo = "Aurora promotion did not complete within 15 minutes" }
        Next   = "RecordFailure"
      }

      RecordPromoted = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName        = aws_dynamodb_table.dr_state.name
          Key              = local.state_key
          UpdateExpression = "SET failover_issued_at = :i, promoted_at = :t"
          ExpressionAttributeValues = {
            ":i" = { S = "{% $failoverIssuedAt %}" }
            ":t" = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "VerifyDrHealth"
      }

      # Do not trust the control plane's word: confirm the DR region actually
      # commits writes, probed from outside via its public endpoint.
      VerifyDrHealth = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.drill_control.arn
          Payload      = { action = "check_health", url = local.secondary_health_url }
        }
        Assign = {
          healthy     = "{% $states.result.Payload.healthy %}"
          verifyPolls = "{% $verifyPolls + 1 %}"
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "DrHealthy"
      }

      DrHealthy = {
        Type = "Choice"
        Choices = [
          { Condition = "{% $healthy = true %}", Next = "MarkSecondaryActive" },
          { Condition = "{% $verifyPolls >= 120 %}", Next = "VerifyTimedOut" },
        ]
        Default = "WaitBeforeVerify"
      }

      WaitBeforeVerify = {
        Type    = "Wait"
        Seconds = 5
        Next    = "VerifyDrHealth"
      }

      VerifyTimedOut = {
        Type   = "Pass"
        Assign = { errorInfo = "DR region promoted but /health did not pass within 10 minutes" }
        Next   = "RecordFailure"
      }

      MarkSecondaryActive = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          UpdateExpression         = "SET #s = :s, verified_at = :t"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":s" = { S = "SECONDARY_ACTIVE" }
            ":t" = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "NotifySuccess"
      }

      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Arguments = {
          TopicArn = aws_sns_topic.dr_events.arn
          Subject  = "[${local.name}] Failover to ${var.secondary_region} complete"
          Message  = "{% 'Writer is now ${aws_rds_cluster.secondary.id} in ${var.secondary_region}. Trigger: ' & $reason & '. Execution: ' & $states.context.Execution.Id %}"
        }
        Retry = local.sfn_retry_transient
        Next  = "Done"
      }

      Done = { Type = "Succeed" }

      AlreadyHandled = {
        Type   = "Succeed"
        Output = { result = "skipped", reason = "a failover is already in progress or the stack is not in PRIMARY_ACTIVE" }
      }

      RecordFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          UpdateExpression         = "SET #s = :s, last_error = :e, failed_at = :t"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":s" = { S = "FAILOVER_FAILED" }
            ":e" = { S = "{% $errorInfo %}" }
            ":t" = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Retry = local.sfn_retry_transient
        Next  = "NotifyFailure"
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Arguments = {
          TopicArn = aws_sns_topic.dr_events.arn
          Subject  = "[${local.name}] FAILOVER FAILED - human action required"
          Message  = "{% 'Failover runbook failed: ' & $errorInfo & '. See docs/runbook.md. Execution: ' & $states.context.Execution.Id %}"
        }
        Retry = local.sfn_retry_transient
        Next  = "Failed"
      }

      Failed = {
        Type  = "Fail"
        Error = "FailoverFailed"
        Cause = "{% $errorInfo %}"
      }
    }
  }

  # --- Failback (planned switchover, zero data loss) -------------------------
  failback_definition = {
    Comment       = "Planned switchover of ${local.name} back to ${var.primary_region}"
    QueryLanguage = "JSONata"
    StartAt       = "GetState"
    States = {
      GetState = {
        Type      = "Task"
        Resource  = "arn:aws:states:::dynamodb:getItem"
        Arguments = { TableName = aws_dynamodb_table.dr_state.name, Key = local.state_key, ConsistentRead = true }
        Assign = {
          drState     = "{% $states.result.Item.state.S %}"
          syncPolls   = 0
          writerPolls = 0
          verifyPolls = 0
          errorInfo   = "none"
        }
        Retry = local.sfn_retry_transient
        Next  = "CanFailBack"
      }

      CanFailBack = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $drState = 'SECONDARY_ACTIVE' %}", Next = "MarkFailingBack" }]
        Default = "NotFailedOver"
      }

      NotFailedOver = {
        Type  = "Fail"
        Error = "NotFailedOver"
        Cause = "{% 'Failback requires state SECONDARY_ACTIVE, found ' & $drState %}"
      }

      MarkFailingBack = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          ConditionExpression      = "#s = :expected"
          UpdateExpression         = "SET #s = :s, failback_started_at = :t"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":expected" = { S = "SECONDARY_ACTIVE" }
            ":s"        = { S = "FAILING_BACK" }
            ":t"        = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Catch = local.sfn_fail_catch
        Next  = "WaitForResync"
      }

      # After an AllowDataLoss failover Aurora rebuilds the old primary as a
      # secondary once it is reachable. Switchover is only safe once it is
      # fully re-synchronised.
      WaitForResync = {
        Type    = "Wait"
        Seconds = 30
        Next    = "CheckResync"
      }

      CheckResync = {
        Type      = "Task"
        Resource  = "arn:aws:states:::aws-sdk:rds:describeGlobalClusters"
        Arguments = { GlobalClusterIdentifier = aws_rds_global_cluster.this.id }
        Assign = {
          primarySync  = "{% ($m := $states.result.GlobalClusters[0].GlobalClusterMembers[DbClusterArn = '${aws_rds_cluster.primary.arn}']; $exists($m.SynchronizationStatus) ? $m.SynchronizationStatus : 'absent') %}"
          globalStatus = "{% $states.result.GlobalClusters[0].Status %}"
          syncPolls    = "{% $syncPolls + 1 %}"
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "Resynced"
      }

      Resynced = {
        Type = "Choice"
        Choices = [
          { Condition = "{% $primarySync = 'connected' and $globalStatus = 'available' %}", Next = "Switchover" },
          { Condition = "{% $syncPolls >= 180 %}", Next = "ResyncTimedOut" },
        ]
        Default = "WaitForResync"
      }

      ResyncTimedOut = {
        Type   = "Pass"
        Assign = { errorInfo = "Old primary did not resynchronise within 90 minutes" }
        Next   = "RecordFailure"
      }

      Switchover = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:rds:switchoverGlobalCluster"
        Arguments = {
          GlobalClusterIdentifier   = aws_rds_global_cluster.this.id
          TargetDbClusterIdentifier = aws_rds_cluster.primary.arn
        }
        Catch = local.sfn_fail_catch
        Next  = "WaitForWriter"
      }

      WaitForWriter = {
        Type    = "Wait"
        Seconds = 10
        Next    = "CheckWriter"
      }

      CheckWriter = {
        Type      = "Task"
        Resource  = "arn:aws:states:::aws-sdk:rds:describeGlobalClusters"
        Arguments = { GlobalClusterIdentifier = aws_rds_global_cluster.this.id }
        Assign = {
          writerArn   = local.writer_expr
          writerPolls = "{% $writerPolls + 1 %}"
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "PrimaryIsWriter"
      }

      PrimaryIsWriter = {
        Type = "Choice"
        Choices = [
          { Condition = "{% $writerArn = '${aws_rds_cluster.primary.arn}' %}", Next = "VerifyPrimaryHealth" },
          { Condition = "{% $writerPolls >= 90 %}", Next = "SwitchoverTimedOut" },
        ]
        Default = "WaitForWriter"
      }

      SwitchoverTimedOut = {
        Type   = "Pass"
        Assign = { errorInfo = "Switchover did not complete within 15 minutes" }
        Next   = "RecordFailure"
      }

      VerifyPrimaryHealth = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.drill_control.arn
          Payload      = { action = "check_health", url = local.primary_health_url }
        }
        Assign = {
          healthy     = "{% $states.result.Payload.healthy %}"
          verifyPolls = "{% $verifyPolls + 1 %}"
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "PrimaryHealthy"
      }

      PrimaryHealthy = {
        Type = "Choice"
        Choices = [
          { Condition = "{% $healthy = true %}", Next = "MarkPrimaryActive" },
          { Condition = "{% $verifyPolls >= 120 %}", Next = "FailbackVerifyTimedOut" },
        ]
        Default = "WaitBeforePrimaryVerify"
      }

      WaitBeforePrimaryVerify = {
        Type    = "Wait"
        Seconds = 5
        Next    = "VerifyPrimaryHealth"
      }

      FailbackVerifyTimedOut = {
        Type   = "Pass"
        Assign = { errorInfo = "Primary is writer again but /health did not pass within 10 minutes (is the FIS fault still active?)" }
        Next   = "RecordFailure"
      }

      MarkPrimaryActive = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          UpdateExpression         = "SET #s = :s, failback_completed_at = :t"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":s" = { S = "PRIMARY_ACTIVE" }
            ":t" = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Retry = local.sfn_retry_transient
        Catch = local.sfn_fail_catch
        Next  = "NotifySuccess"
      }

      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Arguments = {
          TopicArn = aws_sns_topic.dr_events.arn
          Subject  = "[${local.name}] Failback to ${var.primary_region} complete"
          Message  = "{% 'Writer is back on ${aws_rds_cluster.primary.id}. Execution: ' & $states.context.Execution.Id %}"
        }
        Retry = local.sfn_retry_transient
        Next  = "Done"
      }

      Done = { Type = "Succeed" }

      RecordFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Arguments = {
          TableName                = aws_dynamodb_table.dr_state.name
          Key                      = local.state_key
          UpdateExpression         = "SET #s = :s, last_error = :e, failed_at = :t"
          ExpressionAttributeNames = { "#s" = "state" }
          ExpressionAttributeValues = {
            ":s" = { S = "FAILBACK_FAILED" }
            ":e" = { S = "{% $errorInfo %}" }
            ":t" = { S = "{% $states.context.State.EnteredTime %}" }
          }
        }
        Retry = local.sfn_retry_transient
        Next  = "NotifyFailure"
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Arguments = {
          TopicArn = aws_sns_topic.dr_events.arn
          Subject  = "[${local.name}] FAILBACK FAILED - human action required"
          Message  = "{% 'Failback runbook failed: ' & $errorInfo & '. Execution: ' & $states.context.Execution.Id %}"
        }
        Retry = local.sfn_retry_transient
        Next  = "Failed"
      }

      Failed = {
        Type  = "Fail"
        Error = "FailbackFailed"
        Cause = "{% $errorInfo %}"
      }
    }
  }
}

resource "aws_sfn_state_machine" "failover" {
  provider = aws.secondary

  name       = "${local.name}-failover"
  role_arn   = aws_iam_role.runbook.arn
  definition = jsonencode(local.failover_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.states["failover"].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.runbook]
}

resource "aws_sfn_state_machine" "failback" {
  provider = aws.secondary

  name       = "${local.name}-failback"
  role_arn   = aws_iam_role.runbook.arn
  definition = jsonencode(local.failback_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.states["failback"].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.runbook]
}
