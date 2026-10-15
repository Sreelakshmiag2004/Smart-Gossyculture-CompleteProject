terraform {
  # >= 1.11: ephemeral resources + write-only arguments, so generated secrets never enter state.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Partial configuration: environments/<env>.backend.hcl (bucket from ../bootstrap, key per
  # environment, S3-native locking). Staging and production never share state.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "smart-gossyculture"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
