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
log "1/2 — gp3 StorageClass"
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
log "2/2 — AWS Load Balancer Controller"
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
log "verifying"
###############################################################################
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=3m

# Without this CRD the Ingress will be accepted by the API and then silently
# never provisioned, which is the most confusing possible failure mode.
kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null \
  && log "TargetGroupBinding CRD present"

log "done — the cluster can now serve Ingress and provision gp3 volumes"
