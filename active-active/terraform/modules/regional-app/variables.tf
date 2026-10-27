variable "name" {
  description = "Name prefix including region role, e.g. dr-aa-east."
  type        = string
}

variable "api_fqdn" {
  description = "Shared public hostname (the latency-routed record)."
  type        = string
}

variable "hosted_zone_id" {
  description = "Hosted zone for ACM DNS validation."
  type        = string
}

variable "package_path" {
  description = "Path to the app Lambda zip (built by scripts/build.sh, includes the Postgres driver)."
  type        = string
}

variable "package_hash" {
  description = "base64 SHA-256 of the zip, to trigger redeploys."
  type        = string
}

variable "dsql_cluster_arn" {
  description = "This region's DSQL cluster ARN (IAM auth target)."
  type        = string
}

variable "dsql_endpoint" {
  description = "This region's DSQL endpoint hostname."
  type        = string
}

variable "fis_enabled" {
  description = "Attach the AWS FIS Lambda extension so experiments can inject invocation faults."
  type        = bool
  default     = false
}

variable "fis_layer_arn" {
  description = "Regional AWS FIS extension layer ARN (from the public SSM parameter)."
  type        = string
  default     = ""
}

variable "fis_config_bucket" {
  description = "Bucket FIS writes fault configs to; the extension polls it."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type = number
}
