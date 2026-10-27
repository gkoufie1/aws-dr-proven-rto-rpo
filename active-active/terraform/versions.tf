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
  }

  # Partial config - supply bucket/key/region with -backend-config=backend.hcl.
  # Use a different key from the active-passive stack so the two never share state.
  backend "s3" {}
}
