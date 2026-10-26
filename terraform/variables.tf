variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "dr-proof"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars, lowercase letters, digits and hyphens."
  }
}

variable "primary_region" {
  description = "Region that normally serves traffic and holds the Aurora writer."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "DR region. The failover runbook, watchdog and drill orchestration live here so they survive a primary-region outage."
  type        = string
  default     = "us-west-2"
}

variable "hosted_zone_name" {
  description = "Existing public Route 53 hosted zone, e.g. example.com. Failover DNS needs a real domain."
  type        = string
}

variable "api_subdomain" {
  description = "Subdomain for the failover API record, e.g. api-dr -> api-dr.example.com."
  type        = string
  default     = "api-dr"
}

variable "aurora_engine_version" {
  # AWS retires minor versions; check before applying:
  #   aws rds describe-orderable-db-instance-options --engine aurora-postgresql \
  #     --engine-version <v> --db-instance-class db.serverless --query 'OrderableDBInstanceOptions[0].SupportsGlobalDatabases'
  description = "Aurora PostgreSQL version. Must support Global Database, Serverless v2 and Data API, and be identical in both regions."
  type        = string
  default     = "16.15"
}

variable "aurora_min_acu" {
  description = "Serverless v2 minimum capacity per region. Global databases cannot auto-pause, so this is the floor you pay for while the stack exists."
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Serverless v2 maximum capacity per region."
  type        = number
  default     = 2
}

variable "rto_target_seconds" {
  description = "Recovery time objective. A drill whose user-observed outage exceeds this is a FAIL."
  type        = number
  default     = 300
}

variable "rpo_target_seconds" {
  description = "Recovery point objective. A drill that loses acknowledged writes spanning more than this is a FAIL."
  type        = number
  default     = 5
}

variable "auto_failover_enabled" {
  description = "Run the watchdog that triggers the failover runbook automatically. Disable to make failover a human decision (runbook still available)."
  type        = bool
  default     = true
}

variable "watchdog_failure_threshold" {
  description = "Consecutive failed primary health probes (5 s apart) before the watchdog starts the failover runbook."
  type        = number
  default     = 3
}

variable "fault_duration" {
  description = "ISO-8601 duration the FIS experiment keeps the primary impaired."
  type        = string
  default     = "PT10M"
}

variable "pause_dynamodb_replication" {
  description = "Also sever DynamoDB global-table replication during the drill, so the RPO check reflects a real link loss."
  type        = bool
  default     = true
}

variable "drill_schedule_enabled" {
  description = "Run drills on an in-AWS schedule. Leave false when the GitHub Actions workflow drives ephemeral drills (apply -> drill -> destroy)."
  type        = bool
  default     = false
}

variable "drill_schedule_expression" {
  description = "EventBridge Scheduler expression for in-AWS drills."
  type        = string
  default     = "cron(0 14 ? * SAT *)"
}

variable "alert_email" {
  description = "Optional email subscribed to failover/failback notifications. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for all log groups."
  type        = number
  default     = 14
}
