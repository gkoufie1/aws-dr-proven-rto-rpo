variable "project" {
  description = "Name prefix for every resource. Different from the active-passive stack so both can coexist."
  type        = string
  default     = "dr-aa"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars, lowercase letters, digits and hyphens."
  }
}

variable "east_region" {
  description = "First serving region. Also the region the drill impairs."
  type        = string
  default     = "us-east-1"
}

variable "west_region" {
  description = "Second serving region."
  type        = string
  default     = "us-west-2"
}

variable "witness_region" {
  # DSQL multi-Region clusters need a third region that stores only the
  # transaction log, so a quorum survives losing either serving region.
  description = "DSQL witness region (must be in the same region set as the two serving regions)."
  type        = string
  default     = "us-east-2"
}

variable "hosted_zone_name" {
  description = "Existing public Route 53 hosted zone, e.g. dr.example.com."
  type        = string
}

variable "api_subdomain" {
  description = "Subdomain for the latency-routed API record, e.g. aa -> aa.dr.example.com."
  type        = string
  default     = "aa"
}

variable "max_outage_target_seconds" {
  description = "Longest run of failed writes any client may see during a regional impairment. Longer is a FAIL."
  type        = number
  default     = 120
}

variable "health_check_interval" {
  description = "Route 53 health check interval in seconds (10 or 30)."
  type        = number
  default     = 10

  validation {
    condition     = contains([10, 30], var.health_check_interval)
    error_message = "Route 53 supports 10 or 30 second intervals."
  }
}

variable "health_check_failure_threshold" {
  description = "Consecutive failed checks before Route 53 stops routing to a region."
  type        = number
  default     = 2
}

variable "fault_duration" {
  description = "ISO-8601 duration the FIS experiment keeps the east region impaired."
  type        = string
  default     = "PT5M"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for all log groups."
  type        = number
  default     = 14
}
