# One screen that tells the active-active story during a drill: both regions
# healthy -> east health fails -> east client's writes move to west -> back.

locals {
  ns = local.metric_namespace

  dashboard_widgets = [
    {
      type = "text", x = 0, y = 0, width = 24, height = 2
      properties = {
        markdown = "## ${local.name}: active-active (Aurora DSQL multi-Region + Route 53 latency routing)\nBoth regions take writes. During a drill FIS fails every east API call; Route 53 moves east clients to west with no failover runbook and no promotion step."
      }
    },
    {
      type = "metric", x = 0, y = 2, width = 12, height = 6
      properties = {
        title   = "Route 53 health check status (1 = healthy)"
        region  = var.east_region
        view    = "timeSeries"
        stat    = "Minimum"
        period  = 60
        yAxis   = { left = { min = 0, max = 1 } }
        metrics = [for r, hc in aws_route53_health_check.region : ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", hc.id, { label = r }]]
      }
    },
    {
      type = "metric", x = 12, y = 2, width = 12, height = 6
      properties = {
        title  = "East client: acknowledged writes by serving region"
        region = var.witness_region
        view   = "timeSeries"
        stat   = "Sum"
        period = 60
        metrics = concat(
          [for r in [var.east_region, var.west_region] : [local.ns, "WriteAcked", "Client", "east", "ServedBy", r, { label = "served by ${r}" }]],
          [[local.ns, "WriteFailed", "Client", "east", "ServedBy", "none", { label = "failed", color = "#d62728" }]]
        )
      }
    },
    {
      type = "metric", x = 0, y = 8, width = 12, height = 6
      properties = {
        title  = "API requests per region"
        region = var.east_region # required; each metric overrides it with its own region
        view   = "timeSeries"
        stat   = "Sum"
        period = 60
        metrics = [
          ["AWS/ApiGateway", "Count", "ApiId", module.app_east.api_id, { region = var.east_region, label = var.east_region }],
          ["AWS/ApiGateway", "Count", "ApiId", module.app_west.api_id, { region = var.west_region, label = var.west_region }],
        ]
      }
    },
    {
      type = "metric", x = 12, y = 8, width = 12, height = 6
      properties = {
        title  = "West client: acknowledged vs failed writes (should not notice)"
        region = var.west_region
        view   = "timeSeries"
        stat   = "Sum"
        period = 60
        metrics = [
          [local.ns, "WriteAcked", "Client", "west", { label = "acked" }],
          [local.ns, "WriteFailed", "Client", "west", { label = "failed", color = "#d62728" }],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 14, width = 12, height = 6
      properties = {
        title  = "API 5xx per region"
        region = var.east_region # required; each metric overrides it with its own region
        view   = "timeSeries"
        stat   = "Sum"
        period = 60
        metrics = [
          ["AWS/ApiGateway", "5xx", "ApiId", module.app_east.api_id, { region = var.east_region, label = var.east_region, color = "#d62728" }],
          ["AWS/ApiGateway", "5xx", "ApiId", module.app_west.api_id, { region = var.west_region, label = var.west_region, color = "#ff7f0e" }],
        ]
      }
    },
    {
      type = "metric", x = 12, y = 14, width = 12, height = 6
      properties = {
        title  = "Client-observed write latency p50 (ms) - the price of synchronous replication"
        region = var.east_region # required; each metric overrides it with its own region
        view   = "timeSeries"
        stat   = "p50"
        period = 60
        metrics = [
          [local.ns, "WriteLatency", "Client", "east", { region = var.witness_region, label = "east client" }],
          [local.ns, "WriteLatency", "Client", "west", { region = var.west_region, label = "west client" }],
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  provider = aws.east

  dashboard_name = "${local.name}-active-active"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
