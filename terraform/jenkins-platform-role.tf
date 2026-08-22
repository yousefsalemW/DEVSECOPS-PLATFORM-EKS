# =============================================================================
#  Platform deployment role
#
#  THE PROBLEM THIS SOLVES
#
#  jenkins-ec2-role is the STANDING identity of every build. It is deliberately
#  scoped to AmazonEKSEditPolicy on the `vprofile` namespace only (see eks.tf),
#  so a compromised build - or anyone who can merge a commit - cannot read
#  Secrets in kube-system, install webhooks, or touch the platform layer.
#
#  But platform/bootstrap-addons.sh legitimately needs to do exactly those
#  things: it creates a cluster-scoped StorageClass, installs ClusterRoles and
#  admission webhooks with the Load Balancer Controller, and installs 10 CRDs
#  with kube-prometheus-stack.
#
#  Widening jenkins-ec2-role would give that power to EVERY build, permanently.
#  Instead the power lives in a SEPARATE role that must be explicitly assumed,
#  by one manually-triggered pipeline, for the duration of one run.
#
#      jenkins-ec2-role  --sts:AssumeRole-->  jenkins-platform-role
#         (standing, narrow)                    (borrowed, broad)
#
#  What this does and does not buy, stated honestly:
#    DOES  - the application pipeline cannot touch the platform, even if its
#            Jenkinsfile is modified, because its role simply lacks the access.
#    DOES  - every platform change is attributable: CloudTrail records an
#            AssumeRole event with a session name, so "who installed this" has
#            an answer.
#    DOES NOT - stop someone who can edit Jenkinsfile-platform from assuming the
#            role. Anyone with commit access to that file has platform access.
#            Branch protection is what closes that, and it is not configured.
# =============================================================================

resource "aws_iam_role" "jenkins_platform" {
  name        = "jenkins-platform-role"
  description = "Assumed by the platform pipeline to install cluster add-ons"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          # ONLY the Jenkins EC2 role may assume this. Not the account root,
          # not a wildcard - the trust is the security boundary.
          AWS = aws_iam_role.jenkins.arn
        }
      }
    ]
  })

  # An assumed session lasts at most this long. A platform run takes ~15 min;
  # an hour is generous without leaving credentials valid all day.
  max_session_duration = 3600

  tags = {
    Name    = "jenkins-platform-role"
    Purpose = "platform-addons-deployment"
  }
}

# AWS API calls the bootstrap script actually makes. Every one of these was
# read out of the script rather than guessed:
#   aws sts get-caller-identity          - resolve ACCOUNT_ID
#   aws eks describe-cluster             - resolve VPC_ID, and update-kubeconfig
#   aws s3api list-buckets               - find the Velero bucket
#   aws kms describe-key --key-id alias/ - find the Vault unseal key
data "aws_iam_policy_document" "jenkins_platform" {
  statement {
    sid = "ClusterDiscovery"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid = "FindVeleroBucket"
    # list-buckets is unavoidably account-wide - the API has no per-bucket form.
    # It reveals bucket NAMES only, no contents.
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid = "FindVaultUnsealKey"
    # Read-only metadata lookup so the seal stanza can be filled in. The role
    # can neither Encrypt nor Decrypt with it - only Vault's own IRSA role can.
    actions = [
      "kms:DescribeKey",
      "kms:ListAliases",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "jenkins_platform" {
  name        = "jenkins-platform"
  description = "AWS API calls made by platform/bootstrap-addons.sh"
  policy      = data.aws_iam_policy_document.jenkins_platform.json
}

resource "aws_iam_role_policy_attachment" "jenkins_platform" {
  role       = aws_iam_role.jenkins_platform.name
  policy_arn = aws_iam_policy.jenkins_platform.arn
}

# --- EKS access -------------------------------------------------------------
resource "aws_eks_access_entry" "jenkins_platform" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins_platform.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_platform" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins_platform.arn

  # ClusterAdmin, and it genuinely has to be. The narrower AmazonEKSAdminPolicy
  # maps to the Kubernetes `admin` ClusterRole, which is NAMESPACE-scoped and
  # excludes CustomResourceDefinitions, ClusterRoles and webhook configurations
  # - all three of which the add-on charts create. Scoping this down would mean
  # hand-maintaining a ClusterRole that mirrors five upstream charts' RBAC, and
  # re-auditing it on every chart bump.
  #
  # The isolation here is the SEPARATE ROLE, not a reduced policy: this power
  # exists only inside an assumed session, not as a standing grant.
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jenkins_platform]
}

output "jenkins_platform_role_arn" {
  description = "Role the platform pipeline assumes. Set as PLATFORM_ROLE_ARN."
  value       = aws_iam_role.jenkins_platform.arn
}
