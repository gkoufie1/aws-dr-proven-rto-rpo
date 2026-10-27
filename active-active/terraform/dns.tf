# --- Route 53: health-checked latency routing ---------------------------------
# Every client is sent to its nearest healthy region. When a region's /health
# fails (it can no longer reach DSQL, or its compute is down), Route 53 stops
# answering with it and clients move to the other region - and come back on
# their own once it recovers. There is no runbook and no promotion step:
# because both regions are writable, "failover" is just DNS.

resource "aws_route53_health_check" "region" {
  provider = aws.east
  for_each = {
    (var.east_region) = module.app_east.default_endpoint_host
    (var.west_region) = module.app_west.default_endpoint_host
  }

  fqdn              = each.value
  type              = "HTTPS"
  port              = 443
  resource_path     = "/health"
  request_interval  = var.health_check_interval
  failure_threshold = var.health_check_failure_threshold
  enable_sni        = true

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_route53_record" "api" {
  provider = aws.east
  for_each = {
    (var.east_region) = {
      target  = module.app_east.domain_target
      zone_id = module.app_east.domain_zone_id
    }
    (var.west_region) = {
      target  = module.app_west.domain_target
      zone_id = module.app_west.domain_zone_id
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = local.api_fqdn
  type            = "A"
  set_identifier  = each.key
  health_check_id = aws_route53_health_check.region[each.key].id

  latency_routing_policy {
    region = each.key
  }

  alias {
    name                   = each.value.target
    zone_id                = each.value.zone_id
    evaluate_target_health = false
  }
}
