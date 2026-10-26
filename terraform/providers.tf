# Default (unaliased) provider: only used by region-agnostic data sources such
# as aws_iam_policy_document. Every real resource pins aws.primary or
# aws.secondary explicitly so its region is obvious at a glance.
provider "aws" {
  region = var.primary_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {
  provider = aws.primary
}

data "aws_partition" "current" {
  provider = aws.primary
}
