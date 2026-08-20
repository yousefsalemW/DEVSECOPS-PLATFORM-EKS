module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "vprofile-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# --- Velero inputs -----------------------------------------------------------
# Declared here rather than in a variables.tf that does not exist yet; move them
# if one is ever added.
variable "velero_bucket_name" {
  description = "S3 bucket for Velero backups. Bucket names are GLOBALLY unique - change this if the apply fails with BucketAlreadyExists."
  type        = string
  default     = "vprofile-velero-backups-450444046673"
}

variable "velero_retention_days" {
  description = "Days before S3 expires a backup object. Should exceed the Velero schedule TTL so Velero, not S3, decides what is current."
  type        = number
  default     = 35
}
