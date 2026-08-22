#!/usr/bin/env bash
###############################################################################
#  Cluster platform bootstrap — run this ON THE JENKINS EC2, over SSM.
#
#  WHY A SCRIPT AND NOT TERRAFORM:
#    The cluster endpoint is private (cluster_endpoint_public_access = false),
#    so terraform's helm/kubernetes providers cannot reach the API server from
#    outside the VPC. Everything here talks to the Kubernetes API, so it has to
#    run from inside — which is exactly where kubectl and helm already are.
#
#  WHAT IT INSTALLS (idempotent — safe to re-run):
#    1. gp3 StorageClass, made default (gp2 demoted)
#    2. AWS Load Balancer Controller, bound to the existing IRSA role
#    3. kube-prometheus-stack (Prometheus, Grafana, Alertmanager, exporters)
#    4. Velero (backups to S3 + EBS snapshots)
#    5. Vault (single pod, KMS auto-unseal, Agent Injector)
#
#  Vault is INSTALLED here but not CONFIGURED. `vault operator init` prints
#  recovery keys and a root token exactly once; a human must capture those.
#  Run platform/vault-configure.sh afterwards, interactively.
#
#  WHAT IT DELIBERATELY DOES NOT DO:
#    vpc-cni's enableNetworkPolicy is an AWS API call, not a Kubernetes one, so
#    it belongs in terraform where it will not drift. See the README note.
#
#  USAGE:
#    aws ssm start-session --target <jenkins-instance-id> --region eu-west-3
#    sudo -u jenkins -H bash platform/bootstrap-addons.sh
###############################################################################
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vprofile-eks}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
LB_ROLE_NAME="${LB_ROLE_NAME:-vprofile-lb-controller}"   # created by module.lb_role
LB_CHART_VERSION="${LB_CHART_VERSION:-1.13.4}"

# Every chart version lives here, together. This is the same guarantee a
# Chart.lock gives an umbrella chart: one place to read, one place to change,
# and nothing floats. An umbrella was considered and rejected - three of the
# four platform charts hardcode .Release.Namespace and cannot be redirected,
# so an umbrella would force them into one namespace. See
# Guides/PLATFORM-ADDONS-ARCHITECTURE-GUIDE.md for the full reasoning.
MONITORING_CHART_VERSION="${MONITORING_CHART_VERSION:-88.5.0}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
GRAFANA_SECRET="${GRAFANA_SECRET:-grafana-admin}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.1}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-vprofile}"

log() { echo "[addons] $*"; }

###############################################################################
log "resolving cluster identity"
###############################################################################
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
LB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LB_ROLE_NAME}"

# The controller needs the VPC id explicitly; auto-discovery is unreliable when
# the pod runs with IRSA rather than the node role.
VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

log "account ${ACCOUNT_ID} · vpc ${VPC_ID}"
log "lb role  ${LB_ROLE_ARN}"

# Fail early and clearly if kubeconfig is not wired up for THIS user.
kubectl version --request-timeout=15s -o json >/dev/null 2>&1 || {
  log "cannot reach the API server. Run first:"
  log "  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
  exit 1
}
kubectl get nodes --no-headers | awk '{print "[addons]   node " $1 " " $2}'

###############################################################################
log "1/6 — application namespace"
###############################################################################
# Namespaces are cluster-scoped, so the application pipeline cannot create this
# one under its namespace-scoped Edit policy. Platform owns it; the app pipeline
# only ever deploys INTO it. This must also exist before the two credential
# Secrets can be created.
kubectl create namespace "${APP_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

###############################################################################
log "2/6 — gp3 StorageClass"
###############################################################################
# The EBS CSI driver addon is already installed by terraform; this only adds the
# class that uses it. gp3 is cheaper and faster than gp2 at the same size, and
# WaitForFirstConsumer keeps the volume in the same AZ as the pod that claims it.
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
YAML

# Two default StorageClasses is an error state — demote the built-in gp2.
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl patch storageclass gp2 -p \
    '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
  log "gp2 demoted"
fi

kubectl get storageclass

###############################################################################
log "3/6 — AWS Load Balancer Controller"
###############################################################################
# The IRSA trust policy in terraform is scoped to exactly
# system:serviceaccount:kube-system:aws-load-balancer-controller — so the
# ServiceAccount name and namespace below are NOT free choices.
kubectl create serviceaccount aws-load-balancer-controller \
  -n kube-system --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system "eks.amazonaws.com/role-arn=${LB_ROLE_ARN}" --overwrite

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${LB_CHART_VERSION}" \
  --set "clusterName=${CLUSTER_NAME}" \
  --set "region=${AWS_REGION}" \
  --set "vpcId=${VPC_ID}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=1 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=256Mi \
  --wait --timeout 5m

###############################################################################
log "4/6 — kube-prometheus-stack"
###############################################################################
# Grafana's admin password is created out of band, exactly like the database and
# broker credentials: it never enters this script, the values file, or Git.
kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${MONITORING_NAMESPACE}"

if ! kubectl -n "${MONITORING_NAMESPACE}" get secret "${GRAFANA_SECRET}" >/dev/null 2>&1; then
  log "Secret '${GRAFANA_SECRET}' not found in namespace '${MONITORING_NAMESPACE}'."
  log "The monitoring values reference it (grafana.admin.existingSecret). Create it once:"
  log "  kubectl -n ${MONITORING_NAMESPACE} create secret generic ${GRAFANA_SECRET} \\"
  log "    --from-literal=admin-user=admin \\"
  log "    --from-literal=admin-password='<strong password>'"
  exit 1
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

# NOTE ON CRDs: Helm installs files in a chart's crds/ directory on INSTALL only.
# It never upgrades or deletes them. That is a documented Helm limitation, not a
# chart bug. When bumping MONITORING_CHART_VERSION across a major release, apply
# the new CRDs by hand FIRST, or the operator silently runs against a stale API:
#   kubectl apply --server-side -f \
#     https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/<ver>/example/prometheus-operator-crd/...
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NAMESPACE}" \
  --version "${MONITORING_CHART_VERSION}" \
  --values "$(dirname "$0")/values/monitoring.yaml" \
  --wait --timeout 10m

kubectl -n "${MONITORING_NAMESPACE}" rollout status \
  deploy/kube-prometheus-stack-operator --timeout=5m
kubectl -n "${MONITORING_NAMESPACE}" rollout status \
  deploy/kube-prometheus-stack-grafana --timeout=5m

# The Operator materialises Prometheus and Alertmanager as StatefulSets from the
# CRs, so they appear a moment after helm returns - hence a separate wait.
log "waiting for the operator to materialise Prometheus and Alertmanager"
for _ in $(seq 1 30); do
  if kubectl -n "${MONITORING_NAMESPACE}" get statefulset \
       prometheus-kube-prometheus-stack-prometheus >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
kubectl -n "${MONITORING_NAMESPACE}" rollout status \
  statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=10m || \
  log "WARNING: Prometheus did not become ready - check 'kubectl -n ${MONITORING_NAMESPACE} describe pod'"

###############################################################################
log "5/6 — Velero"
###############################################################################
# The bucket and IAM role are created by terraform/velero.tf. Both are read
# from live AWS rather than hardcoded, for the same reason ECR_REGISTRY is
# derived at runtime: the script then works in any account without editing.
VELERO_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/vprofile-velero"

VELERO_BUCKET="$(aws s3api list-buckets --region "${AWS_REGION}" \
  --query "Buckets[?starts_with(Name, 'vprofile-velero-backups')].Name | [0]" \
  --output text 2>/dev/null || true)"

if [ -z "${VELERO_BUCKET}" ] || [ "${VELERO_BUCKET}" = "None" ]; then
  log "no Velero bucket found. Run 'terraform apply' first - it creates the"
  log "bucket and the IAM role that this step annotates the ServiceAccount with."
  exit 1
fi
log "bucket ${VELERO_BUCKET}"
log "role   ${VELERO_ROLE_ARN}"

kubectl get namespace "${VELERO_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${VELERO_NAMESPACE}"

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null

helm upgrade --install velero vmware-tanzu/velero \
  --namespace "${VELERO_NAMESPACE}" \
  --version "${VELERO_CHART_VERSION}" \
  --values "$(dirname "$0")/values/velero.yaml" \
  --set "serviceAccount.server.annotations.eks\\.amazonaws\\.com/role-arn=${VELERO_ROLE_ARN}" \
  --set "configuration.backupStorageLocation[0].bucket=${VELERO_BUCKET}" \
  --wait --timeout 5m

kubectl -n "${VELERO_NAMESPACE}" rollout status deploy/velero --timeout=5m

# A BackupStorageLocation that cannot reach its bucket reports Unavailable and
# every backup fails. Velero validates it on a timer, so give it a moment -
# this catches a broken IRSA trust immediately instead of at 02:00 tomorrow.
log "waiting for the BackupStorageLocation to validate"
for _ in $(seq 1 18); do
  phase="$(kubectl -n "${VELERO_NAMESPACE}" get backupstoragelocation default \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${phase}" = "Available" ] && break
  sleep 10
done
if [ "${phase:-}" = "Available" ]; then
  log "BackupStorageLocation is Available"
else
  log "WARNING: BackupStorageLocation is '${phase:-unknown}', not Available."
  log "  Almost always the IRSA trust: check that terraform trusts"
  log "  ${VELERO_NAMESPACE}:velero-server and that the SA carries the role ARN."
fi

###############################################################################
log "6/6 — Vault"
###############################################################################
VAULT_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/vprofile-vault"

VAULT_KMS_KEY_ID="$(aws kms describe-key --region "${AWS_REGION}" \
  --key-id alias/vprofile-vault-unseal \
  --query 'KeyMetadata.KeyId' --output text 2>/dev/null || true)"

if [ -z "${VAULT_KMS_KEY_ID}" ] || [ "${VAULT_KMS_KEY_ID}" = "None" ]; then
  log "KMS alias 'alias/vprofile-vault-unseal' not found. Run 'terraform apply'"
  log "first - it creates the key and the IAM role Vault unseals itself with."
  exit 1
fi
log "kms key ${VAULT_KMS_KEY_ID}"
log "role    ${VAULT_ROLE_ARN}"

kubectl get namespace "${VAULT_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${VAULT_NAMESPACE}"

helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

# The seal stanza needs the account-specific key id, so the values file carries
# placeholders and they are substituted here. sed on a temp copy rather than
# --set: the config is a raw HCL string and --set would mangle it.
VAULT_VALUES="$(mktemp)"
trap 'rm -f "${VAULT_VALUES}"' EXIT
sed -e "s|AWS_REGION_PLACEHOLDER|${AWS_REGION}|" \
    -e "s|KMS_KEY_ID_PLACEHOLDER|${VAULT_KMS_KEY_ID}|" \
    "$(dirname "$0")/values/vault.yaml" > "${VAULT_VALUES}"

# NO --wait here, unlike every other step. Vault's pod is NOT Ready until it is
# initialised and unsealed, and it cannot be initialised until it is running.
# Waiting for Ready would deadlock until the timeout.
helm upgrade --install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --version "${VAULT_CHART_VERSION}" \
  --values "${VAULT_VALUES}" \
  --set "server.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${VAULT_ROLE_ARN}"

log "waiting for the vault-0 pod to be Running (it will NOT be Ready yet)"
for _ in $(seq 1 30); do
  phase="$(kubectl -n "${VAULT_NAMESPACE}" get pod vault-0 \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${phase}" = "Running" ] && break
  sleep 10
done

if [ "${phase:-}" != "Running" ]; then
  log "WARNING: vault-0 is '${phase:-unknown}'. Check 'kubectl -n ${VAULT_NAMESPACE} describe pod vault-0'"
fi

###############################################################################
log "verifying"
###############################################################################
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=3m

# Without this CRD the Ingress will be accepted by the API and then silently
# never provisioned, which is the most confusing possible failure mode.
kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null \
  && log "TargetGroupBinding CRD present"

kubectl -n "${MONITORING_NAMESPACE}" get pods --no-headers \
  | awk '{print "[addons]   " $1 " " $3}'

log ""
log "Grafana is NOT exposed - reach it with a port-forward, like Jenkins:"
log "  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/kube-prometheus-stack-grafana 3000:80"
log "  then http://localhost:3000  (user from the ${GRAFANA_SECRET} secret)"
log ""
kubectl -n "${VELERO_NAMESPACE}" get backupstoragelocation,schedule --no-headers 2>/dev/null \
  | awk '{print "[addons]   " $1 " " $2}'

log ""
kubectl -n "${VAULT_NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '{print "[addons]   " $1 " " $2 " " $3}'

log ""
log "VAULT IS INSTALLED BUT NOT CONFIGURED. Next, run interactively:"
log "  kubectl -n ${VAULT_NAMESPACE} exec -it vault-0 -- vault operator init \\"
log "    -recovery-shares=3 -recovery-threshold=2      # store the output SAFELY"
log "  export VAULT_TOKEN='hvs....'"
log "  bash platform/vault-configure.sh"

log ""
log "KNOWN GAPS, deliberately not covered here:"
log "  - Alertmanager has NO receivers. Alerts fire and go nowhere."
log "  - RESTORE HAS NEVER BEEN TESTED. An untested backup is a hypothesis."
log "      velero backup create test --include-namespaces vprofile --wait"
log "      velero restore create --from-backup test --namespace-mappings vprofile:vprofile-restore"
log "  - No log aggregation (Loki / Fluent Bit)."
log "  - The application exposes no JVM metrics - infrastructure only."
log "  - Vault is a SINGLE POD. If it dies, secret delivery stops until it returns."
log "  - Vault's own data needs 'vault operator raft snapshot save', not an EBS snapshot."
log "  - The app still reads credentials from Kubernetes Secrets, not Vault."

log "done — Ingress, gp3 volumes, monitoring, backups and Vault are in place"
