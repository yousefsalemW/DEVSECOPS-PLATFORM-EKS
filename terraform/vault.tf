# =============================================================================
#  Vault — KMS auto-unseal key and IRSA identity
#
#  WHY AUTO-UNSEAL MATTERS MORE THAN IT SOUNDS
#
#  Vault starts SEALED. Its storage is encrypted with a master key that Vault
#  itself cannot read until it is unsealed. Without auto-unseal, a human must
#  paste unseal key shares EVERY time the pod restarts - after a node drain, an
#  OOM kill, a chart upgrade, a spot reclamation. That is not operable: it means
#  Vault is down until someone is awake, and every application that depends on
#  it is down too.
#
#  With awskms seal, Vault asks KMS to decrypt its master key at startup using
#  the pod's IRSA identity. No human, no stored key shares.
#
#  The trade-off, stated plainly: the KMS key becomes a dependency of Vault
#  starting AT ALL. Delete it and the data is unrecoverable - which is why
#  deletion_window_in_days is set to the maximum and rotation is enabled rather
#  than the key being replaced.
# =============================================================================

resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal (vprofile)"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name    = "vprofile-vault-unseal"
    Purpose = "vault-auto-unseal"
  }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/vprofile-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# The upstream IAM module has no built-in Vault policy, so this is written by
# hand - deliberately narrow: three actions on ONE key.
data "aws_iam_policy_document" "vault_unseal" {
  statement {
    sid = "VaultAutoUnseal"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_policy" "vault_unseal" {
  name        = "vprofile-vault-unseal"
  description = "Allows Vault to auto-unseal with its KMS key"
  policy      = data.aws_iam_policy_document.vault_unseal.json
}

module "vault_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "vprofile-vault"

  role_policy_arns = {
    unseal = aws_iam_policy.vault_unseal.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Namespace-qualified, like every other SA identity here. If this and the
      # chart's serviceAccount name ever disagree, Vault starts, reports
      # healthy, and stays SEALED with an AccessDenied in its logs.
      namespace_service_accounts = ["vault:vault"]
    }
  }
}

output "vault_kms_key_id" {
  description = "KMS key id for the Vault awskms seal stanza"
  value       = aws_kms_key.vault_unseal.key_id
}

output "vault_role_arn" {
  description = "IAM role ARN to annotate the vault ServiceAccount with"
  value       = module.vault_role.iam_role_arn
}
