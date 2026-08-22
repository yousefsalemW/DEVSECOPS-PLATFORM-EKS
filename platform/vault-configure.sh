#!/usr/bin/env bash
# =============================================================================
#  Vault post-install configuration
#
#  DELIBERATELY SEPARATE FROM bootstrap-addons.sh, for one reason:
#
#  `vault operator init` prints RECOVERY KEYS and a ROOT TOKEN exactly once,
#  and they are never retrievable again. Those must be captured by a human and
#  stored somewhere safe - not scrolled past in CI output, not written to a
#  Jenkins build log that lives on disk for 15 builds.
#
#  So the bootstrap script installs Vault and stops. This script is run by a
#  person, interactively, and it refuses to be helpful about where the keys go.
#
#  WHAT IT CONFIGURES
#    1. Kubernetes auth  - lets pods authenticate with their SA token
#    2. A KV v2 mount    - where the application's secrets live
#    3. A policy         - read access to exactly one path
#    4. A role           - binds vprofile:app01 to that policy, nothing else
#
#  Run it from the Jenkins box, as a human, after bootstrap-addons.sh.
# =============================================================================
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-vprofile}"
VAULT_POD="${VAULT_POD:-vault-0}"

log() { printf '[vault] %s\n' "$*"; }
vex() { kubectl -n "${VAULT_NAMESPACE}" exec -i "${VAULT_POD}" -- "$@"; }

###############################################################################
log "checking Vault status"
###############################################################################
# `vault status` exits 2 when sealed and 0 when unsealed - both are normal, so
# the exit code is captured rather than allowed to trip set -e.
status="$(vex vault status -format=json 2>/dev/null || true)"

initialised="$(printf '%s' "${status}" | jq -r '.initialized // false')"
sealed="$(printf '%s' "${status}" | jq -r '.sealed // true')"
log "initialized=${initialised} sealed=${sealed}"

if [ "${initialised}" != "true" ]; then
  cat <<'EOF'

  Vault is not initialised yet. Run this YOURSELF and store the output somewhere
  safe before continuing - it is printed once and cannot be recovered:

    kubectl -n vault exec -it vault-0 -- vault operator init \
      -recovery-shares=3 -recovery-threshold=2

  With KMS auto-unseal these are RECOVERY keys, not unseal keys: Vault unseals
  itself on restart, and the recovery keys exist for the case where you need to
  regenerate the root token or the KMS key becomes unusable. They still matter.

  Then re-run this script.

EOF
  exit 1
fi

if [ "${sealed}" = "true" ]; then
  log "Vault is initialised but SEALED. With awskms seal this should not happen."
  log "Almost always the IRSA trust or the KMS policy. Check:"
  log "  kubectl -n ${VAULT_NAMESPACE} logs ${VAULT_POD} | grep -i 'kms\\|seal\\|denied'"
  exit 1
fi

###############################################################################
log "authenticating"
###############################################################################
if [ -z "${VAULT_TOKEN:-}" ]; then
  cat <<'EOF'

  VAULT_TOKEN is not set. Export the root token from `vault operator init`:

    export VAULT_TOKEN='hvs....'

  Use it for this configuration and then REVOKE it - a root token that lives
  forever is the thing Vault exists to avoid:

    kubectl -n vault exec -it vault-0 -- vault token revoke -self

EOF
  exit 1
fi

vault_do() { vex env VAULT_TOKEN="${VAULT_TOKEN}" vault "$@"; }

###############################################################################
log "1/4 — Kubernetes auth method"
###############################################################################
# Enabling twice is an error, so tolerate "path is already in use".
vault_do auth enable kubernetes 2>/dev/null \
  || log "  kubernetes auth already enabled"

# Vault validates SA tokens by calling the cluster's TokenReview API. Inside the
# cluster it can discover the endpoint from its own environment, so no host,
# CA cert or reviewer token needs to be passed - that is the modern default and
# it avoids storing a long-lived reviewer JWT.
vault_do write auth/kubernetes/config \
  kubernetes_host="https://\$KUBERNETES_PORT_443_TCP_ADDR:443"

###############################################################################
log "2/4 — KV v2 secrets engine at vprofile/"
###############################################################################
vault_do secrets enable -path=vprofile -version=2 kv 2>/dev/null \
  || log "  vprofile/ already mounted"

###############################################################################
log "3/4 — policy"
###############################################################################
# Read on ONE path. Not read on vprofile/*, not sudo, not list on everything.
# The whole point of the ServiceAccount work was to make a policy this narrow
# meaningful - it applies to app01 and to nothing else.
vault_do policy write vprofile-app - <<'POLICY'
path "vprofile/data/app01" {
  capabilities = ["read"]
}
POLICY

###############################################################################
log "4/4 — role binding vprofile:app01 to that policy"
###############################################################################
vault_do write auth/kubernetes/role/vprofile-app \
  bound_service_account_names=app01 \
  bound_service_account_namespaces="${APP_NAMESPACE}" \
  policies=vprofile-app \
  ttl=1h

cat <<EOF

[vault] configured.

  Write the application's secrets:

    kubectl -n ${VAULT_NAMESPACE} exec -it ${VAULT_POD} -- \\
      env VAULT_TOKEN="\$VAULT_TOKEN" vault kv put vprofile/app01 \\
        jdbc_password='<the database password>' \\
        rabbitmq_password='<the broker password>'

  Verify the role works from the app's identity - this proves the whole chain
  (SA token -> TokenReview -> policy) before any pod depends on it:

    TOKEN=\$(kubectl -n ${APP_NAMESPACE} create token app01)
    kubectl -n ${VAULT_NAMESPACE} exec -i ${VAULT_POD} -- \\
      vault write auth/kubernetes/login role=vprofile-app jwt="\$TOKEN"

  Then REVOKE the root token:

    kubectl -n ${VAULT_NAMESPACE} exec -it ${VAULT_POD} -- \\
      env VAULT_TOKEN="\$VAULT_TOKEN" vault token revoke -self

  NOT DONE YET, and deliberately so:
    - The application still reads its credentials from Kubernetes Secrets.
      Switching it to Vault needs the injector annotations on app01 AND a
      change to how the app reads them - Spring resolves placeholders at
      STARTUP, so a rotated secret needs a pod restart either way.
    - Vault's own data has no backup. Use 'vault operator raft snapshot save',
      not an EBS snapshot - see the note in platform/values/vault.yaml.
    - Static secrets only. Dynamic database credentials are where Vault earns
      its keep, and that is a separate piece of work.

EOF
