variable "name" {
  description = "Name prefix including region role, e.g. dr-proof-primary."
  type        = string
}

variable "region_role" {
  description = "primary or secondary - surfaced in API responses so probes can tell which region served them."
  type        = string

  validation {
    condition     = contains(["primary", "secondary"], var.region_role)
    error_message = "region_role must be primary or secondary."
  }
}

variable "api_fqdn" {
  description = "Shared public hostname (the Route 53 failover record)."
  type        = string
}

variable "hosted_zone_id" {
  description = "Hosted zone for ACM DNS validation."
  type        = string
}

variable "package_path" {
  description = "Path to the app Lambda zip."
  type        = string
}

variable "package_hash" {
  description = "base64 SHA-256 of the zip, to trigger redeploys."
  type        = string
}

variable "db_cluster_arn" {
  description = "This region's Aurora cluster ARN (Data API target)."
  type        = string
}

variable "db_secret_arn" {
  description = "This region's copy of the DB credentials secret."
  type        = string
}

variable "db_name" {
  type = string
}

variable "table_name" {
  description = "DynamoDB global table name (same in every region)."
  type        = string
}

variable "table_arn" {
  description = "This region's replica ARN."
  type        = string
}

variable "kms_key_arn" {
  description = "This region's data key (DynamoDB SSE)."
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
