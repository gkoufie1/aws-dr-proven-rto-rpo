# Lives in the DR region so it is still reachable when the primary is not.
# Widgets pull metrics cross-region via the per-widget "region" property.

resource "aws_cloudwatch_dashboard" "dr" {
  provider = aws.secondary

  dashboard_name = "${local.name}-dr"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Route 53 health (1 = can commit writes)"
          region = "us-east-1" # Route 53 health-check metrics only exist here
          stat   = "Minimum"
          period = 60
          metrics = [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.region["primary"].id, { label = var.primary_region }],
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.region["secondary"].id, { label = var.secondary_region }],
          ]
          yAxis = { left = { min = 0, max = 1 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Watchdog view of primary (from ${var.secondary_region})"
          region = var.secondary_region
          stat   = "Average"
          period = 60
          metrics = [
            ["DRProof", "PrimaryHealthy", "Project", local.name],
          ]
          yAxis = { left = { min = 0, max = 1 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Aurora Global DB replication lag (ms) - RPO exposure"
          region = var.secondary_region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/RDS", "AuroraGlobalDBReplicationLag", "DBClusterIdentifier", aws_rds_cluster.secondary.cluster_identifier],
            ["AWS/RDS", "AuroraGlobalDBRPOLag", "DBClusterIdentifier", aws_rds_cluster.secondary.cluster_identifier],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB global table replication latency (ms)"
          region = var.primary_region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/DynamoDB", "ReplicationLatency", "TableName", aws_dynamodb_table.ledger.name, "ReceivingRegion", var.secondary_region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "Runbook executions"
          region = var.secondary_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.failover.arn, { label = "failover ok" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.failover.arn, { label = "failover failed" }],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.drill.arn, { label = "drill ok" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.drill.arn, { label = "drill errored" }],
          ]
        }
      },
    ]
  })
}
