terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "eu-west-3"

  default_tags {
    tags = {
      Project   = "vprofile"
      ManagedBy = "Terraform"
      Owner     = "ALnaqib"
    }
  }
}
