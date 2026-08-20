# =============================================================================
#  Velero — backup storage and identity
#
#  Terraform owns the AWS half only: the bucket and the IAM role. The Velero
#  server itself is installed by platform/bootstrap-addons.sh, because it talks
#  to the Kubernetes API and the cluster endpoint is private.
#
#  SCOPE, stated honestly: Velero backs up Kubernetes OBJECTS and takes EBS
#  snapshots. An EBS snapshot of a running MySQL volume is CRASH-consistent,
#  not application-consistent - InnoDB usually recovers, but "usually" is not a
#  backup strategy. The chart values add a pre-backup mysqldump hook to close
#  that gap. See platform/values/velero.yaml.
# =============================================================================

resource "aws_s3_bucket" "velero" {
  bucket = var.velero_bucket_name

  # Backups are the thing you reach for when everything else failed. Refusing to
  # delete the bucket while it still holds them is the correct default.
  force_destroy = false

  tags = {
    Name    = var.velero_bucket_name
    Purpose = "velero-backups"
  }
}

# Velero writes immutable backup objects, but versioning protects against the
# one case Velero cannot: someone deleting or overwriting them by hand.
resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Velero's own TTL removes the backup RECORDS; this removes the objects that
# outlive them, including old versions. Without it the bucket only ever grows.
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.velero_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# IRSA. attach_velero_policy is a maintained policy in the upstream module -
# EBS snapshot create/delete/describe plus scoped S3 access. Writing it by hand
# would mean maintaining an AWS permissions list nobody reviews.
module "velero_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name            = "vprofile-velero"
  attach_velero_policy = true
  # BUCKET arn, NOT "arn/*". The module appends /* itself for the object
  # statement and uses the bare ARN for s3:ListBucket. Passing an
  # already-suffixed value produces "bucket/*/*" and silently breaks writes.
  velero_s3_bucket_arns = [aws_s3_bucket.velero.arn]

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Namespace-qualified, like every other SA identity. Changing the
      # namespace here without changing it in the chart breaks the trust
      # silently: Velero starts, looks healthy, and every AWS call is denied.
      namespace_service_accounts = ["velero:velero-server"]
    }
  }
}

output "velero_bucket" {
  description = "S3 bucket holding Velero backups"
  value       = aws_s3_bucket.velero.id
}

output "velero_role_arn" {
  description = "IAM role ARN to annotate the velero-server ServiceAccount with"
  value       = module.velero_role.iam_role_arn
}
