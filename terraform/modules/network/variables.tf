variable "name" {
  description = "Name prefix, including the region role (e.g. dr-proof-primary)."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Use non-overlapping ranges per region so the VPCs can be peered later."
  type        = string
}
