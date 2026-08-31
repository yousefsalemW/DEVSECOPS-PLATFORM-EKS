# VProfile DevSecOps Platform on Amazon EKS

A production-shaped deployment of the VProfile multi-tier Java application on Amazon EKS, built
with Terraform, delivered by Jenkins, and operated with monitoring, backup and secrets management.

**Region:** `eu-west-3` · **Cluster:** `vprofile-eks` (Kubernetes 1.34) · **IaC:** Terraform ≥ 1.10

---

## Overview

VProfile is a five-tier Java web application — nginx, Tomcat, MySQL, Memcached and RabbitMQ. This
repository contains everything needed to build it, ship it and run it:

- A three-AZ VPC and a private EKS cluster, entirely in Terraform
- A Jenkins pipeline that builds, analyses, scans, generates SBOMs, pushes to ECR and deploys via Helm
- A separate, manually-triggered platform pipeline that installs cluster add-ons under an assumed IAM role
- Prometheus and Grafana for cluster observability
- Velero for namespace and volume backup to S3
- HashiCorp Vault with Kubernetes authentication and least-privilege policies

All five data services run **in-cluster as containers**. This project deliberately does not use RDS,
ElastiCache or Amazon MQ — see [Production Considerations](docs/VPROFILE-DEVOPS-GUIDE.md#17-production-considerations)
for what would change in a real production environment.

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
   Developer ──push──►  │  GitHub                                 │
                        └──────────────────┬──────────────────────┘
                                           │ webhook
                        ┌──────────────────▼──────────────────────┐
                        │  Jenkins  (EC2, private subnet, SSM)    │
                        │  Maven → SonarQube → Trivy → ECR → Helm │
                        └──────────────────┬──────────────────────┘
                                           │
        ┌──────────────────────────────────▼───────────────────────────────┐
        │  AWS  eu-west-3                                                  │
        │  ┌────────────────────────────────────────────────────────────┐  │
        │  │  VPC 10.0.0.0/16 — 3 AZs                                   │  │
        │  │                                                            │  │
        │  │   Public  10.0.1-3.0/24    ALB  ·  NAT ×3  ·  IGW          │  │
        │  │   Private 10.0.11-13.0/24  EKS worker nodes ×3             │  │
        │  │                                                            │  │
        │  │   ┌──────────────── EKS 1.34 (private endpoint) ────────┐  │  │
        │  │   │ vprofile    nginx → tomcat → mysql/memcached/rabbit │  │  │
        │  │   │ monitoring  Prometheus · Grafana · Alertmanager     │  │  │
        │  │   │ velero      Velero                                  │  │  │
        │  │   │ vault       Vault (Raft, KMS auto-unseal)           │  │  │
        │  │   │ kube-system ALB Controller · EBS CSI · CoreDNS      │  │  │
        │  │   └─────────────────────────────────────────────────────┘  │  │
        │  └────────────────────────────────────────────────────────────┘  │
        │      ECR (5 repos)   ·   S3 (Velero + TF state)   ·   KMS        │
        └───────────────────────────────────────────────────────────────────┘
```

Detailed diagrams: [`docs/architecture/`](docs/architecture/)

---

## Technology Stack

Only technologies actually deployed in this project are listed.

| Layer | Technology | Version / Detail |
|---|---|---|
| **Cloud** | AWS | `eu-west-3` (Paris), 3 AZs |
| **IaC** | Terraform | ≥ 1.10, S3 backend with native locking |
| | AWS provider | ~> 5.0 |
| | Community modules | vpc ~> 5.0, eks ~> 20.0, iam ~> 5.0 |
| **Containers** | Docker | Multi-stage build for the Java app |
| | Amazon ECR | 5 repositories with lifecycle policies |
| **Kubernetes** | Amazon EKS | 1.34, managed node group, private endpoint |
| | Helm | Application chart (25 objects) |
| | AWS Load Balancer Controller | 1.13.4 |
| | EBS CSI driver | EKS managed add-on, `gp3` StorageClass |
| **CI/CD** | Jenkins | Declarative pipeline, 10 stages + Deploy |
| | Maven | Build and unit tests |
| **Security** | SonarQube | 26.8.0 community, self-hosted |
| | Trivy | Image scanning + CycloneDX SBOM |
| | HashiCorp Vault | Chart 0.34.1, Raft storage, KMS auto-unseal |
| | Kubernetes NetworkPolicies | 6 policies, default-deny |
| **Monitoring** | kube-prometheus-stack | 88.5.0 (Prometheus, Grafana, Alertmanager) |
| **Backup** | Velero | Chart 12.1.0, EBS snapshots to S3 |
| **Data services** | MySQL 8.0.43 · Memcached 1.6.38 · RabbitMQ 3.13 | All **in-cluster containers** |

**Not used in this project:** RDS, ElastiCache, Amazon MQ, Route 53, ACM, CloudWatch dashboards,
Elasticsearch (removed during image hardening).

---

## CI/CD

Two separate pipelines with separate IAM identities.

### Application pipeline — `Jenkinsfile`

Triggered on push. Runs as `jenkins-ec2-role`, whose EKS access is scoped to the `vprofile`
namespace only.

```
GitHub
   ↓
Init            resolve commit SHA, build tag, ECR registry
   ↓
Maven Verify    compile + unit tests
   ↓
SonarQube       static analysis + quality gate
   ↓
Build           5 Docker images
   ↓
Trivy Scan      vulnerability GATE + CycloneDX SBOM per image (fails on fixable HIGH/CRITICAL)
   ↓
ECR Login       authenticate to the registry
   ↓
Tag / Push      images tagged <git-sha>-<build-number>
   ↓
Verify          confirm each manifest exists in ECR
   ↓
Deploy          helm upgrade --install --atomic
```

### Platform pipeline — `Jenkinsfile-platform`

Manually triggered, no webhook. Assumes `jenkins-platform-role` via STS for the duration of one
run, then delegates entirely to `platform/bootstrap-addons.sh`.

```
Assume Platform Role → Connect → Report → Approval gate → Deploy
```

`ACTION` defaults to `verify` (read-only) so an accidental build changes nothing.

---

## Security

| Control | Implementation |
|---|---|
| **Least privilege — CI** | `jenkins-ec2-role` holds `AmazonEKSEditPolicy` scoped to namespace `vprofile`. It cannot read Secrets in `kube-system`, `vault` or `monitoring`. |
| **Privilege separation** | Platform work requires `sts:AssumeRole` into a distinct role. The broad grant exists only inside a one-hour assumed session, recorded in CloudTrail. |
| **Workload identity** | 4 IRSA roles — ALB Controller, EBS CSI, Velero, Vault. No static AWS keys anywhere. |
| **Per-workload ServiceAccounts** | 5 ServiceAccounts, one per workload; `automountServiceAccountToken: false` on the 4 that never call the API. |
| **Network segmentation** | 6 NetworkPolicies: default-deny both directions, explicit allows only. Enforcement enabled via `vpc-cni` `enableNetworkPolicy`. |
| **Secrets at rest** | EKS secret encryption with a customer-managed KMS key. No credential values in Git — the chart refuses to render without externally-created Secrets. |
| **Container hardening** | All 6 containers: `allowPrivilegeEscalation: false`, `drop: ALL`, `seccompProfile: RuntimeDefault`. Non-root where the image permits. |
| **Supply chain** | Trivy gate before ECR login — fixable HIGH/CRITICAL findings fail the build, so a vulnerable image never reaches the registry. Accepted risks are recorded with written justification in `Build-Images/.trivyignore`. CycloneDX SBOM archived per image per build. |
| **Access** | Jenkins reached via SSM Session Manager. No bastion, no SSH key, no open port 22. |


---

## Monitoring

`kube-prometheus-stack` 88.5.0 in the `monitoring` namespace.

- **Prometheus** — 7-day retention, 10 GiB `gp3` volume, `retentionSize: 8GiB` as a safety net
- **Grafana** — 24 auto-provisioned dashboards, admin password from an externally-created Secret
- **Exporters** — node-exporter (DaemonSet) and kube-state-metrics
- **EKS-specific tuning** — `kubeEtcd`, `kubeControllerManager`, `kubeScheduler` and `kubeProxy`
  scraping **and their alert rules** are disabled, because those components are AWS-managed and
  unreachable. Leaving them on produces four permanently-firing alerts from day one.

Measured footprint: 375m CPU / 1.4 GiB RAM requests / 14 GiB EBS.


---

## Backup & Disaster Recovery

Velero 12.1.0 in the `velero` namespace, authenticating to S3 via IRSA (no static credentials).

- **Two schedules** — `daily-vprofile` (02:00 UTC, 30-day TTL, volume snapshots on) and
  `weekly-platform` (Sunday 03:00, 14-day TTL, objects only)
- **Application consistency** — a pre-backup hook runs `mysqldump --single-transaction` into the
  volume so the EBS snapshot captures both the datadir and a known-good logical dump
- **Retention layering** — the S3 lifecycle rule expires objects at 35 days, deliberately longer
  than the 30-day Velero TTL, so Velero remains the component that decides what is current

**Status of DR testing — stated precisely:**

```
Backup Configured  ✅   Backup Successful  ✅ 
```

A restore was executed against a deleted namespace. It returned **`PartiallyFailed`** with 1 error
and 4 warnings. The database PVC did recover (it carries `velero.io/restore-name` and bound
successfully), but no data integrity check was performed and the root cause of the error was not
captured. **Disaster recovery is not validated.**

---

## Repository Structure

```text
├── terraform/                  All AWS infrastructure
│   ├── vpc.tf                  VPC, 3 AZs, subnets, NAT ×3
│   ├── eks.tf                  EKS 1.34, node group, add-ons, IRSA, access entries
│   ├── ecr-jenkins.tf          5 ECR repos, Jenkins EC2, IAM, security groups
│   ├── jenkins-platform-role.tf  Assumable platform role + EKS ClusterAdmin entry
│   ├── velero.tf               S3 bucket + Velero IRSA role
│   ├── vault.tf                KMS auto-unseal key + Vault IRSA role
│   └── jenkins-userdata.sh     Jenkins + SonarQube + tooling bootstrap
│
├── Build-Images/               Application container builds
│   ├── src/                    VProfile Java source
│   ├── images/{app,db,memcached,rabbitmq}/Dockerfile
│   └── .trivyignore            Accepted CVEs, with reasons
│
├── docker/web/                 nginx reverse proxy image + config
│
├── helm/vprofile/              Application Helm chart — 25 objects
│   └── templates/              SAs, workloads, ingress, PDBs, NetworkPolicies
│
├── platform/                   Cluster add-ons
│   ├── bootstrap-addons.sh     6-step installer, all chart versions pinned
│   ├── vault-configure.sh      Interactive Vault setup (kept out of CI by design)
│   └── values/                 monitoring · velero · vault
│
├── Jenkinsfile                 Application pipeline
├── Jenkinsfile-platform        Platform pipeline (manual, AssumeRole)
│
├── docs/                       Documentation, diagrams, evidence
└── archive/PATCHES/            Historical change sets (reference only)
```

---

## Documentation

| Document | Contents |
|---|---|
| [**Technical Guide**](docs/VPROFILE-DEVOPS-GUIDE.md) | Full 19-section reference — architecture, IaC, CI/CD, security, DR, real problems solved |
| [**Architecture Diagrams**](docs/architecture/) | 7 layered diagrams |
| [**Screenshot Evidence**](docs/SCREENSHOTS.md) | 31 screenshots classified by what each proves — and does not prove |
| [**Presentation**](docs/presentation/) | 15-slide deck outline |

---

## Deployment

```bash
# 1. Infrastructure
cd terraform && terraform init && terraform apply

# 2. Platform add-ons — via the platform pipeline, or directly on the Jenkins host
bash platform/bootstrap-addons.sh

# 3. Secrets (created out of band — never in Git)
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password='<strong>'
kubectl -n vprofile create secret generic db01-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD='<strong>'
kubectl -n vprofile create secret generic rmq01-credentials \
  --from-literal=RABBITMQ_DEFAULT_USER=vprofile --from-literal=RABBITMQ_DEFAULT_PASS='<strong>'

# 4. Vault — interactive, prints recovery keys once
kubectl -n vault exec -it vault-0 -- vault operator init -recovery-shares=3 -recovery-threshold=2
export VAULT_TOKEN='<root token>' && bash platform/vault-configure.sh

# 5. Application — push a commit, or build the pipeline manually
```

---

**ALnaqib** — DevOps Engineer · [GitHub](https://github.com/yousefsalemW) · [LinkedIn](https://linkedin.com/in/yousef-salem-1a5757401)
