module "network_primary" {
  source    = "./modules/network"
  providers = { aws = aws.primary }

  name               = "${local.name}-primary"
  cidr_block         = "10.40.0.0/16"
  availability_zones = [for s in ["a", "b", "c"] : "${var.primary_region}${s}"]
}

module "network_secondary" {
  source    = "./modules/network"
  providers = { aws = aws.secondary }

  name               = "${local.name}-secondary"
  cidr_block         = "10.41.0.0/16"
  availability_zones = [for s in ["a", "b", "c"] : "${var.secondary_region}${s}"]
}
