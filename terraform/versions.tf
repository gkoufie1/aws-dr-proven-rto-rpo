terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial config - supply bucket/key/region with -backend-config=backend.hcl.
  # Remote state is not optional here: the drill workflow applies and destroys
  # an Aurora Global Database, and a lost local state file means orphaned spend.
  backend "s3" {}
}
