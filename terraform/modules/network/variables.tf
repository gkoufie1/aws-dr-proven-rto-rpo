variable "name" {
  description = "Name prefix, including the region role (e.g. dr-proof-primary)."
  type        = string
}

variable "availability_zones" {
  description = "Exactly three AZ names to place subnets in."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Provide exactly three availability zones."
  }
}

variable "cidr_block" {
  description = "VPC CIDR. Use non-overlapping ranges per region so the VPCs can be peered later."
  type        = string
}
