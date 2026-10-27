# One regional copy of the active-active application: Lambda behind an HTTP
# API, published on the shared hostname through a regional custom domain.
# Both regions are identical and both serve traffic all the time.

locals {
  fis_prefix = "FisConfigs/"

  fis_env = var.fis_enabled ? {
    AWS_FIS_CONFIGURATION_LOCATION = "arn:aws:s3:::${var.fis_config_bucket}/${local.fis_prefix}"
    AWS_LAMBDA_EXEC_WRAPPER        = "/opt/aws-fis/bootstrap"
    AWS_FIS_EXTENSION_METRICS      = "all"
  } : {}
}

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  # IAM authentication to this region's DSQL endpoint as the `app` database
  # role (not admin). No password or secret exists anywhere.
  statement {
    sid       = "DsqlConnect"
    actions   = ["dsql:DbConnect"]
    resources = [var.dsql_cluster_arn]
  }

  dynamic "statement" {
    for_each = var.fis_enabled ? [1] : []
    content {
      sid       = "FisConfigList"
      actions   = ["s3:ListBucket"]
      resources = ["arn:aws:s3:::${var.fis_config_bucket}"]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${local.fis_prefix}*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.fis_enabled ? [1] : []
    content {
      sid       = "FisConfigRead"
      actions   = ["s3:GetObject"]
      resources = ["arn:aws:s3:::${var.fis_config_bucket}/${local.fis_prefix}*"]
    }
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# --- Function ----------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/lambda/${var.name}-app"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "app" {
  function_name    = "${var.name}-app"
  role             = aws_iam_role.app.arn
  runtime          = "python3.12"
  architectures    = ["x86_64"] # FIS extension layer is per-architecture; keep in sync
  handler          = "handler.handler"
  filename         = var.package_path
  source_code_hash = var.package_hash
  timeout          = 10 # API Gateway caps integrations at 10 s anyway
  memory_size      = 256
  layers           = var.fis_enabled ? [var.fis_layer_arn] : []

  environment {
    variables = merge({
      DSQL_ENDPOINT = var.dsql_endpoint
      DB_USER       = "app"
    }, local.fis_env)
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.app, aws_cloudwatch_log_group.app]
}

# --- HTTP API ----------------------------------------------------------------

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-api"
  protocol_type = "HTTP"
  # The default execute-api endpoint stays enabled on purpose: Route 53 health
  # checks probe each region directly, bypassing latency-routed DNS.
}

resource "aws_apigatewayv2_integration" "app" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "this" {
  for_each = toset(["GET /health", "POST /orders", "GET /orders"])

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.app.id}"
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 25
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId = "$context.requestId"
      time      = "$context.requestTime"
      route     = "$context.routeKey"
      status    = "$context.status"
      latencyMs = "$context.responseLatency"
      error     = "$context.integrationErrorMessage"
      userAgent = "$context.identity.userAgent"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# --- Custom domain (regional cert; same hostname in both regions) -----------

resource "aws_acm_certificate" "api" {
  domain_name       = var.api_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM issues the same validation CNAME for a given domain in every region, so
# both regional modules write the same record; allow_overwrite makes that safe.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.api.domain_validation_options : o.domain_name => o
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = var.api_fqdn

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "api" {
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.api.id
  stage       = aws_apigatewayv2_stage.default.id
}
