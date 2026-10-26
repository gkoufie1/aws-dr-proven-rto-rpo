# Small wrapper so every control-plane function gets the same baseline:
# its own role, an inline least-privilege policy, a retained log group and
# X-Ray tracing.

variable "name" {
  type = string
}

variable "description" {
  type = string
}

variable "package_path" {
  type = string
}

variable "package_hash" {
  type = string
}

variable "policy_json" {
  description = "Inline policy with the function's business permissions (logs/X-Ray are added here)."
  type        = string
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "timeout" {
  type    = number
  default = 30
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "log_retention_days" {
  type = number
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "baseline" {
  source_policy_documents = [var.policy_json]

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "function"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.baseline.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = var.description
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = var.package_path
  source_code_hash = var.package_hash
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment {
    variables = var.environment
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.this]
}

output "arn" {
  value = aws_lambda_function.this.arn
}

output "name" {
  value = aws_lambda_function.this.function_name
}

output "role_name" {
  value = aws_iam_role.this.name
}
