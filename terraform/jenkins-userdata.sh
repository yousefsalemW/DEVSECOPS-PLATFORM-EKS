#!/bin/bash
###############################################################################
# Jenkins bootstrap - DevSecOps EKS platform
#
#   Target  : Ubuntu 22.04 LTS  (ami-015cabafc8f6249fe / eu-west-3)
#   Runs    : once, as root, via cloud-init user_data
#   Log     : /var/log/cloud-init-output.log
#   Marker  : /var/log/userdata-complete   (written only on full success)
#
#   Installs: OpenJDK 21, Jenkins, Docker, git, kubectl, Helm, AWS CLI v2, Trivy
#
#   Verify after boot (over SSM):
#     ls -l /var/log/userdata-complete
#     sudo tail -60 /var/log/cloud-init-output.log
#     sudo cat /var/lib/jenkins/secrets/initialAdminPassword
###############################################################################
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# kubectl must stay within +/- 1 minor of the EKS control plane (cluster = 1.34).
# The "stable" channel is already 1.36, which is outside the supported skew.
KUBECTL_MINOR="1.34"

WORKDIR="$(mktemp -d)"
cd "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
trap 'echo "[userdata] *** FAILED on line ${LINENO} ***" >&2' ERR

log() { echo "[userdata] $(date -u '+%H:%M:%S') $*"; }

# Cloud-init can start before the NAT route is usable, and apt mirrors flake.
# Retry anything that touches the network instead of dying on the first miss.
retry() {
  local attempt=1 max=10
  until "$@"; do
    if [ "${attempt}" -ge "${max}" ]; then
      log "gave up after ${max} attempts: $*"
      return 1
    fi
    log "attempt ${attempt}/${max} failed, retrying in 15s: $*"
    attempt=$((attempt + 1))
    sleep 15
  done
}

###############################################################################
log "waiting for outbound connectivity"
###############################################################################
retry curl -fsS --max-time 10 -o /dev/null https://checkip.amazonaws.com

###############################################################################
log "installing base packages"
###############################################################################
retry apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  docker.io \
  git \
  gnupg \
  jq \
  maven \
  openjdk-21-jdk \
  unzip \
  wget

###############################################################################
log "configuring Docker"
###############################################################################
# Cap container log growth - the root volume is only 30 GB and it also holds
# the Jenkins workspace, the Maven cache and the Trivy DB.
install -d -m 0755 /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON

systemctl enable docker
systemctl restart docker

###############################################################################
log "installing Jenkins"
###############################################################################
retry wget -q -O /usr/share/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

retry apt-get update
apt-get install -y jenkins

###############################################################################
log "installing kubectl ${KUBECTL_MINOR}"
###############################################################################
KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt")"
retry curl -fsSL -o kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
retry curl -fsSL -o kubectl.sha256 \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --status
install -m 0755 kubectl /usr/local/bin/kubectl

###############################################################################
log "installing Helm"
###############################################################################
retry curl -fsSL -o get-helm-3 \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get-helm-3
./get-helm-3

###############################################################################
log "installing AWS CLI v2"
###############################################################################
retry curl -fsSL -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update

###############################################################################
log "installing Trivy"
###############################################################################
retry wget -qO trivy.key https://aquasecurity.github.io/trivy-repo/deb/public.key
gpg --batch --yes --dearmor -o /usr/share/keyrings/trivy.gpg trivy.key

# "generic" is the literal channel name in the Trivy repo - not a distro codename.
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list

retry apt-get update
apt-get install -y trivy

###############################################################################
log "wiring Jenkins up"
###############################################################################
# Group membership does not reach an already-running process, and the Jenkins
# postinst has already started the service - so this needs an explicit restart
# at the very end, after every binary is on disk.
usermod -aG docker jenkins

# Pre-create the Trivy cache the pipeline points at (TRIVY_CACHE_DIR).
install -d -m 0755 -o jenkins -g jenkins /var/lib/jenkins/.cache/trivy

systemctl enable jenkins
systemctl restart jenkins

###############################################################################
log "verifying the install"
###############################################################################
for binary in git docker kubectl helm aws trivy java mvn jq; do
  command -v "${binary}" >/dev/null || { log "MISSING BINARY: ${binary}"; exit 1; }
done

# Jenkins must actually be able to reach the Docker socket, or every
# 'docker build' in the pipeline fails with a permission error.
runuser -u jenkins -- docker info >/dev/null

systemctl is-active --quiet docker
systemctl is-active --quiet jenkins

log "git     $(git --version)"
log "docker  $(docker --version)"
log "kubectl $(kubectl version --client=true -o json | jq -r .clientVersion.gitVersion)"
log "helm    $(helm version --short)"
log "aws     $(aws --version)"
log "trivy   $(trivy --version | head -1)"
log "java    $(java -version 2>&1 | head -1)"

touch /var/log/userdata-complete
log "bootstrap complete"
