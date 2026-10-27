# Default (unaliased) provider: only used by region-agnostic data sources such
# as aws_iam_policy_document. Every real resource pins a region explicitly.
provider "aws" {
  region = var.east_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "east"
  region = var.east_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "west"
  region = var.west_region

  default_tags {
    tags = local.tags
  }
}

# Witness region for DSQL, and home of the east-side synthetic client: close
# enough to us-east-1 that latency routing sends it there, but outside the
# region being impaired.
provider "aws" {
  alias  = "witness"
  region = var.witness_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {
  provider = aws.east
}

data "aws_partition" "current" {
  provider = aws.east
}
