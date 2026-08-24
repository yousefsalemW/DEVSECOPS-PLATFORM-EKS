# VProfile DevSecOps Platform — Technical Guide

**Repository:** `github.com/yousefsalemW/DEVSECOPS-PLATFORM-EKS`
**Region:** `eu-west-3` · **Cluster:** `vprofile-eks` · **Kubernetes:** 1.34
**Audit basis:** commit `48e113d`, 49 commits, 51 tracked files

> Every statement in this guide is traceable to a file in the repository. Where something is
> configured but unverified, or written but unused, it is labelled as such rather than presented
> as working. The [Documentation Audit](#documentation-audit) at the end lists all such cases.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Project Overview](#2-project-overview)
3. [Requirements & Goals](#3-requirements--goals)
4. [Final Architecture](#4-final-architecture)
5. [Architecture Components](#5-architecture-components)
6. [Infrastructure as Code](#6-infrastructure-as-code)
7. [Containerization](#7-containerization)
8. [Kubernetes](#8-kubernetes)
9. [CI/CD](#9-cicd)
10. [Code Quality & Security](#10-code-quality--security)
11. [Vault](#11-vault)
12. [Monitoring & Observability](#12-monitoring--observability)
13. [Backup & Disaster Recovery](#13-backup--disaster-recovery)
14. [Security Architecture](#14-security-architecture)
15. [Deployment Workflow](#15-deployment-workflow)
16. [Troubleshooting & Real Problems Solved](#16-troubleshooting--real-problems-solved)
17. [Production Considerations](#17-production-considerations)
18. [Lessons Learned](#18-lessons-learned)
19. [Final Architecture](#19-final-architecture)
20. [Documentation Audit](#documentation-audit)

---

## 1. Executive Summary

This project takes VProfile — a five-tier Java web application — from source code to a running,
observable, backed-up deployment on Amazon EKS, with every layer defined as code.

**What was built:**

| Layer | Delivered |
|---|---|
| Infrastructure | 3-AZ VPC, private EKS 1.34 cluster, 5 ECR repositories, Jenkins host — all Terraform |
| Delivery | Jenkins pipeline: Maven → SonarQube → Trivy + SBOM → ECR → Helm deploy |
| Platform | Separate manually-triggered pipeline installing 5 cluster add-ons under an assumed role |
| Observability | Prometheus + Grafana, 24 dashboards, EKS-specific tuning |
| Backup | Velero to S3 with EBS snapshots and MySQL consistency hooks |
| Secrets | Vault with Kubernetes auth, Raft storage, KMS auto-unseal |
| Segmentation | 6 NetworkPolicies with enforcement enabled at the CNI |

**Engineering decisions that define this project:**

1. **Two pipelines, two identities.** The application pipeline's EKS access is scoped to one
   namespace. Platform work requires an explicit `sts:AssumeRole` into a separate role. This
   means a compromised build — or an edited `Jenkinsfile` — cannot touch `kube-system` or read
   Vault's secrets.

2. **A shell script, not an umbrella Helm chart, for platform add-ons.** This was tested rather
   than assumed: three of the four add-on charts hardcode `.Release.Namespace` and cannot be
   redirected, so an umbrella would have forced them into a single namespace, collapsing the
   security boundary between Vault and everything else.

3. **Backups tested, not assumed.** The restore was executed. It **partially failed**. That result
   is documented here rather than omitted, because an untested backup is a hypothesis and a
   partially-tested one is a known risk — both are more useful than an unqualified claim.

**Honest scope statement:** this is a lab-scale deployment on a budget-constrained AWS account.
Data services run in-cluster rather than as managed services, there is no TLS, and Vault is a
single pod. Section 17 separates what exists from what production would require.

---

## 2. Project Overview

### The application

VProfile is a Java web application used as a realistic multi-tier workload. It comprises:

| Tier | Component | Image | Port |
|---|---|---|---|
| Web | nginx reverse proxy | `nginx:1.27-alpine` | 80 |
| Application | Tomcat + Spring/Hibernate WAR | `tomcat:9.0-jre11-temurin-jammy` | 8080 |
| Database | MySQL | `mysql:8.0.43` | 3306 |
| Cache | Memcached | `memcached:1.6.38-alpine` | 11211 |
| Messaging | RabbitMQ | `rabbitmq:3.13-management-alpine` | 5672 / 15672 |

The application is not the point — the platform around it is. VProfile was chosen because it has
genuine multi-tier dependencies: persistent state, a cache, a message broker, and session
handling that breaks in interesting ways under horizontal scaling.

### What this repository provides

Everything required to reproduce the deployment from an empty AWS account: infrastructure code,
container builds, a Helm chart, two CI/CD pipelines, and platform installation scripts.

---

## 3. Requirements & Goals

### Functional
- Deploy all five tiers to Kubernetes with persistent storage for the database
- Expose the application through an AWS Application Load Balancer
- Automate build and deployment from a Git push

### Non-functional
- **Reproducible** — a destroyed environment rebuilds from code with no undocumented manual steps
- **Least privilege** — no component holds permissions beyond what it demonstrably needs
- **Observable** — cluster and workload resource metrics available before problems occur
- **Recoverable** — application state backed up off-cluster, and the restore path exercised
- **Cost-bounded** — the environment can be destroyed and rebuilt to control spend

### Explicit non-goals
- High availability of the platform layer (Vault is a single pod, by decision)
- TLS termination (no ACM certificate or Route 53 zone)
- Production-grade alert routing
- Multi-environment promotion (dev/staging/prod)

---

## 4. Final Architecture

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ AWS  eu-west-3                                                                │
│                                                                               │
│  ┌─── VPC  vprofile-vpc  10.0.0.0/16 ─────────────────────────────────────┐   │
│  │                                                                        │   │
│  │   AZ eu-west-3a          AZ eu-west-3b          AZ eu-west-3c          │   │
│  │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │   │
│  │  │ PUBLIC       │       │ PUBLIC       │       │ PUBLIC       │        │   │
│  │  │ 10.0.1.0/24  │       │ 10.0.2.0/24  │       │ 10.0.3.0/24  │        │   │
│  │  │  NAT-a       │       │  NAT-b       │       │  NAT-c       │        │   │
│  │  │  ALB ────────┼───────┼──────────────┼───────┼────────      │        │   │
│  │  └──────┬───────┘       └──────┬───────┘       └──────┬───────┘        │   │
│  │         │                      │                      │                │   │
│  │  ┌──────▼───────┐       ┌──────▼───────┐       ┌──────▼───────┐        │   │
│  │  │ PRIVATE      │       │ PRIVATE      │       │ PRIVATE      │        │   │
│  │  │ 10.0.11.0/24 │       │ 10.0.12.0/24 │       │ 10.0.13.0/24 │        │   │
│  │  │  node-1      │       │  node-2      │       │  node-3      │        │   │
│  │  │  Jenkins EC2 │       │              │       │              │        │   │
│  │  └──────────────┘       └──────────────┘       └──────────────┘        │   │
│  │                                                                        │   │
│  │   EKS control plane — private endpoint only, KMS-encrypted secrets      │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                                                                               │
│   ECR ×5      S3: velero-backups + tf-state      KMS: cluster + vault-unseal   │
│   IAM: 2 Jenkins roles + 4 IRSA roles                                         │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Namespaces inside the cluster:**

| Namespace | Contents |
|---|---|
| `vprofile` | The application — 4 Deployments, 1 StatefulSet, 5 Services, Ingress, 6 NetworkPolicies, 3 PDBs, 5 ServiceAccounts |
| `monitoring` | Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter |
| `velero` | Velero server + AWS plugin |
| `vault` | Vault (Raft) + Agent Injector |
| `kube-system` | ALB Controller, EBS CSI, CoreDNS, kube-proxy, VPC CNI |

---

## 5. Architecture Components

### 5.1 AWS

Single region `eu-west-3` (Paris), single account. All resources carry default tags applied at the
provider level: `Project=vprofile`, `ManagedBy=Terraform`, `Owner=ALnaqib`.

### 5.2 VPC

`terraform/vpc.tf`, using `terraform-aws-modules/vpc/aws ~> 5.0`.

| Setting | Value | Reasoning |
|---|---|---|
| CIDR | `10.0.0.0/16` | 65k addresses — the VPC CNI assigns a real VPC IP per pod, so address space is consumed faster than in a nodeport model |
| AZs | 3 | Matches the node group's `desired_size = 3`, one node per AZ |
| Public subnets | `10.0.1-3.0/24` | ALB and NAT gateways |
| Private subnets | `10.0.11-13.0/24` | Worker nodes and Jenkins |
| `one_nat_gateway_per_az` | `true` | Zone-redundant egress — see the trade-off below |
| `enable_dns_hostnames` | `true` | Required by EKS for node registration |

**Subnet tags** are what make ALB provisioning work:
```hcl
public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }
private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
```
Without these the AWS Load Balancer Controller cannot select subnets, and an Ingress is accepted
by the API server while no ALB is ever created — a silent failure.

**The NAT trade-off, stated openly:** three NAT gateways cost roughly **$3.46/day** against $1.15
for one. The alternative — a single NAT — introduces a single-AZ dependency for all outbound
traffic and incurs cross-AZ data transfer charges. Availability was chosen over cost. For a
development environment, `single_nat_gateway = true` is the defensible choice and the module
supports it with one line.

### 5.3 Networking

| Component | Count | Notes |
|---|---|---|
| Internet Gateway | 1 | Public subnet egress |
| NAT Gateways | 3 | One per AZ, each with its own Elastic IP |
| Route tables | 5 | 1 public (shared by 3 subnets) + 3 private (one each) + default |

Private subnets have **independent** route tables. A shared private table would have defeated the
three-NAT design entirely — all private traffic would exit through whichever NAT the single table
pointed at.

### 5.4 EKS

`terraform/eks.tf`, using `terraform-aws-modules/eks/aws ~> 20.0`.

```hcl
cluster_name    = "vprofile-eks"
cluster_version = "1.34"
subnet_ids      = module.vpc.private_subnets
enable_irsa     = true

cluster_endpoint_public_access  = false
cluster_endpoint_private_access = true
```

**The private-only endpoint is the most consequential decision in this file.** It means the API
server is unreachable from the internet — including from the engineer's laptop. Every
`kubectl` and `helm` operation must originate from inside the VPC, which is why the Jenkins host
doubles as the operations jump box (reached via SSM, not SSH).

The direct consequence: Terraform cannot use the `kubernetes` or `helm` providers, because
`terraform apply` runs from outside the VPC and could not reach the API. This is precisely why
platform add-ons are installed by a script that runs on the Jenkins host rather than by Terraform.

**Control plane logging** — five log types enabled: `api`, `audit`, `authenticator`,
`controllerManager`, `scheduler`.

**Secret encryption:**
```hcl
create_kms_key            = true
cluster_encryption_config = { resources = ["secrets"] }
```
Kubernetes Secrets are encrypted at rest with a customer-managed KMS key, not just etcd's default
encryption.

**Add-ons managed in Terraform:**

| Add-on | Configuration |
|---|---|
| `coredns` | Default |
| `kube-proxy` | Default |
| `vpc-cni` | `enableNetworkPolicy = "true"` |
| `aws-ebs-csi-driver` | Declared **outside** the module with its own IRSA role |

The `vpc-cni` setting deserves emphasis. NetworkPolicy enforcement is **off by default**. Without
it the API server accepts every NetworkPolicy, `kubectl get netpol` displays them, and **nothing
is enforced** — which is worse than having no policies at all, because it looks like segmentation
exists. The comment in `eks.tf` says exactly this.

The EBS CSI add-on is declared as a separate `aws_eks_addon` resource rather than inside
`cluster_addons` to break a dependency cycle: the add-on needs an IRSA role ARN, and the IRSA
role needs the cluster's OIDC provider ARN, which the module produces.

### 5.5 Compute

| Resource | Specification |
|---|---|
| EKS node group `workers` | `m7i-flex.large`, min 3 / desired 3 / max 5, private subnets |
| Jenkins EC2 | `m7i-flex.large`, 80 GiB root volume, private subnet, no public IP |

The Jenkins host runs Jenkins (systemd), SonarQube 26.8.0 (Docker container bound to
`127.0.0.1:9000`), Docker, kubectl, helm, AWS CLI and Trivy — provisioned by
`terraform/jenkins-userdata.sh`.

SonarQube's loopback binding is deliberate: the analysis server is reachable only from the Jenkins
process on the same host, never from the VPC network.

### 5.6 Database

**MySQL 8.0.43 runs as an in-cluster StatefulSet**, not RDS.

| Aspect | Implementation |
|---|---|
| Workload | StatefulSet `db01`, 1 replica |
| Storage | `volumeClaimTemplates` → 8 GiB `gp3` PVC |
| Credentials | `db01-credentials` Secret, created out of band |
| Backup | Velero EBS snapshot + `mysqldump` pre-hook |

This is a **single point of failure with no read replica and no automated failover**. It is
appropriate for a lab and inappropriate for production; section 17 addresses the alternative.

Memcached and RabbitMQ are likewise in-cluster Deployments, not ElastiCache or Amazon MQ.

### 5.7 Container Registry

Five ECR repositories created with `for_each`:

```
vprofile-app   vprofile-db   vprofile-mc   vprofile-rmq   vprofile-web
```

Each carries a lifecycle policy. Images are tagged `<git-sha>-<build-number>` — never `latest` by
default (`PUSH_LATEST` defaults to `false`), so every running image traces to an exact commit.

### 5.8 Storage

| Type | Use |
|---|---|
| EBS `gp3` | Default StorageClass; MySQL 8 GiB, Prometheus 10 GiB, Grafana 2 GiB, Alertmanager 2 GiB, Vault 4 GiB |
| S3 | Velero backups (versioned, AES256, public access blocked, 35-day lifecycle); Terraform state (native S3 locking) |

`bootstrap-addons.sh` creates the `gp3` StorageClass and **demotes `gp2`** from default, so any
PVC without an explicit class gets `gp3`.

### 5.9 IAM

**Two Jenkins roles:**

| Role | Trust | AWS permissions | EKS access |
|---|---|---|---|
| `jenkins-ec2-role` | EC2 service | SSM Core, ECR PowerUser, `eks:DescribeCluster`, `sts:AssumeRole` (one ARN) | `AmazonEKSEditPolicy` scoped to namespace `vprofile` |
| `jenkins-platform-role` | **Only** `jenkins-ec2-role` | `eks:Describe/List`, `s3:ListAllMyBuckets`, `kms:DescribeKey/ListAliases` | `AmazonEKSClusterAdminPolicy`, cluster-scoped |

**Four IRSA roles:**

| Role | ServiceAccount | Purpose |
|---|---|---|
| `vprofile-lb-controller` | `kube-system:aws-load-balancer-controller` | Manage ALBs |
| `vprofile-ebs-csi` | `kube-system:ebs-csi-controller-sa` | Provision EBS volumes |
| `vprofile-velero` | `velero:velero-server` | S3 + EBS snapshots |
| `vprofile-vault` | `vault:vault` | KMS Encrypt/Decrypt/DescribeKey on **one** key |

The platform role's KMS permission is read-only metadata (`DescribeKey`, `ListAliases`) — it
locates the key so the script can substitute its ID, but **cannot encrypt or decrypt with it**.
Only Vault's own IRSA role can.

### 5.10 Load Balancing

AWS Load Balancer Controller 1.13.4 in `kube-system`, provisioning an ALB from the Ingress:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
alb.ingress.kubernetes.io/healthcheck-path: /login
alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=86400
```

**`target-type: ip`** sends traffic directly to pod IPs rather than through node ports — one less
hop, possible because the VPC CNI gives every pod a real VPC address.

**Stickiness is load-bearing, not cosmetic.** VProfile stores sessions in memory. With two `app01`
replicas and no affinity, a CSRF token issued by one pod is rejected by the other. This
annotation, combined with `sessionAffinity: ClientIP` on the `app01` Service, is what makes login
and registration work — see §16 Problem 1.

---

## 6. Infrastructure as Code

### Structure

```text
terraform/
├── providers.tf              AWS ~> 5.0, region, default tags
├── backend.tf                S3 backend, native locking (use_lockfile)
├── vpc.tf                    VPC module + Velero variables
├── eks.tf                    EKS module, add-ons, IRSA, access entries
├── ecr-jenkins.tf            ECR ×5, Jenkins EC2, IAM, security groups
├── jenkins-platform-role.tf  Assumable platform role
├── velero.tf                 S3 bucket + IRSA
├── vault.tf                  KMS key + IRSA
└── jenkins-userdata.sh       Host bootstrap
```

### Modules used

| Module | Version | Why a module rather than raw resources |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | ~> 5.0 | Subnet/route/NAT wiring across 3 AZs is ~40 resources of boilerplate |
| `terraform-aws-modules/eks/aws` | ~> 20.0 | Node groups, launch templates, OIDC provider, access entries |
| `.../iam-role-for-service-accounts-eks` | ~> 5.0 | IRSA trust policy construction is easy to get subtly wrong |

**A trap this module caused, and how it was caught:** `attach_velero_policy` takes
`velero_s3_bucket_arns`. Reading the module source shows it **appends `/*` itself** for the object
statement and uses the bare ARN for `s3:ListBucket`. Passing `"${arn}/*"` — the intuitive value —
produces `bucket/*/*` and silently breaks writes. The code passes the bare ARN with a comment
explaining why.

### State

```hcl
backend "s3" {
  bucket       = "vprofilealnaqib777"
  key          = "eks/terraform.tfstate"
  region       = "eu-west-3"
  use_lockfile = true
}
```

`use_lockfile` uses S3-native conditional writes instead of a DynamoDB lock table — one fewer
resource to provision and pay for.

### Variables and outputs

Only two variables, both for Velero (`velero_bucket_name`, `velero_retention_days`). Eight outputs
expose the Jenkins instance ID and private IP, the platform role ARN, and the Velero and Vault
resource identifiers that `bootstrap-addons.sh` consumes.

### Design decisions

| Decision | Reasoning |
|---|---|
| Private-only cluster endpoint | Removes the API server from the internet; forces in-VPC operations |
| No `kubernetes`/`helm` Terraform providers | They could not reach a private endpoint from a laptop — this is a consequence of the above, not an oversight |
| EBS CSI add-on outside the EKS module | Breaks the OIDC-ARN ↔ add-on dependency cycle |
| `force_destroy = false` on the Velero bucket | Refusing to delete a bucket that still holds backups is the correct default |
| KMS `deletion_window_in_days = 30` + rotation | The unseal key is a hard dependency of Vault starting at all |

---

## 7. Containerization

### Image inventory

| Image | Base | Build |
|---|---|---|
| `vprofile-app` | `maven:3.9.9-eclipse-temurin-11` → `tomcat:9.0-jre11-temurin-jammy` | **Multi-stage** |
| `vprofile-db` | `mysql:8.0.43` | Single-stage + schema seed |
| `vprofile-mc` | `memcached:1.6.38-alpine` | Single-stage |
| `vprofile-rmq` | `rabbitmq:3.13-management-alpine` | Single-stage |
| `vprofile-web` | `nginx:1.27-alpine` | Single-stage + config |

### Multi-stage build

Only the application image needs one, and it matters most there:

```dockerfile
FROM maven:3.9.9-eclipse-temurin-11 AS build
# ... mvn package
FROM tomcat:9.0-jre11-temurin-jammy
# ... copy only the WAR
USER tomcat
EXPOSE 8080
```

The final image contains the WAR and a JRE — no Maven, no `~/.m2` cache, no source. Alpine bases
were chosen for three of the five images to reduce the vulnerability surface.

### Non-root

`app` runs as `USER tomcat`, `memcached` as `USER memcache`. MySQL, RabbitMQ and nginx retain
their upstream entrypoints, which require specific capabilities — handled in the Helm chart's
security contexts (§8) rather than by fighting the images.

### Tagging

```
<git-sha>-<build-number>      e.g.  3c37774b-3
```

Immutable and traceable. `latest` is not pushed by default.

### Accepted vulnerabilities

`Build-Images/.trivyignore` holds CVEs accepted with reasons rather than being silenced by
lowering `GATE_SEVERITY` — the distinction between a documented exception and a weakened control.

---

## 8. Kubernetes

### Chart inventory

`helm/vprofile` renders **25 objects**:

| Kind | Count | Names |
|---|---|---|
| ServiceAccount | 5 | `app01`, `db01`, `mc01`, `rmq01`, `vproweb` |
| Deployment | 4 | `app01` (2), `vproweb` (2), `mc01` (1), `rmq01` (1) |
| StatefulSet | 1 | `db01` (1) |
| Service | 5 | one per workload |
| Ingress | 1 | ALB |
| PodDisruptionBudget | 3 | `app01`, `vproweb`, `db01` |
| NetworkPolicy | 6 | see below |

### ServiceAccounts

Each workload has its own identity, with `automountServiceAccountToken: false` on the four that
never call the Kubernetes API. Only `app01` keeps its token, because the Vault Agent Injector
would use it to authenticate.

**This exists because of Vault.** Vault's Kubernetes auth maps a policy to a
`namespace:serviceaccount` pair. When every pod shared the `default` ServiceAccount, any policy
written against `default` would have granted the database password to the nginx pods as well.

### Storage

```yaml
volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: gp3
      resources: { requests: { storage: 8Gi } }
```

### Secrets

The chart **refuses to render** without externally-created Secrets:

```
fail "db credentials missing …"
fail "rabbitmq credentials missing …"
```

No credential value exists in Git. `db01-credentials` and `rmq01-credentials` are created by hand
before the first deploy; the pipeline's `preflight()` checks both and exits with the exact
`kubectl create secret` command if either is absent.

### Security contexts

All six containers:
```yaml
allowPrivilegeEscalation: false
capabilities: { drop: ["ALL"] }
seccompProfile: { type: RuntimeDefault }
```

With targeted exceptions where the upstream image requires them — `db01` and `rmq01` add back
`CHOWN FOWNER DAC_OVERRIDE SETUID SETGID` because their entrypoints use `gosu`; `vproweb` adds
`NET_BIND_SERVICE` because nginx binds port 80.

`readOnlyRootFilesystem` is **not** implemented — it needs emptyDir volumes for Tomcat's work and
temp directories, nginx's cache, and MySQL's datadir. Listed in §17.

### PodDisruptionBudgets

| PDB | minAvailable | Effect |
|---|---|---|
| `app01` | 1 of 2 | Survives a rolling node drain |
| `vproweb` | 1 of 2 | Same |
| `db01` | 1 of 1 | **Deliberately blocks drain** |

The `db01` PDB is intentional: a single-replica database should not be evicted silently by a node
drain. The escape hatch is documented — `kubectl delete pdb db01`.

### NetworkPolicies

Six policies, enforced because `vpc-cni` has `enableNetworkPolicy = "true"`:

| Policy | Rule |
|---|---|
| `default-deny` | Deny all ingress **and** egress in `vprofile` |
| `allow-dns` | Egress to `kube-system` DNS — *the classic way a first rollout breaks everything* |
| `vproweb-ingress` | Ingress from the VPC CIDR `10.0.0.0/16` |
| `vproweb-egress` | Egress to `app01:8080` |
| `app01` | Ingress from `vproweb`; egress to db01:3306, mc01:11211, rmq01:5672 |
| `backends-ingress` | Accept only from `app01`, no egress beyond DNS |

**`vproweb-ingress` uses an `ipBlock`, not a `podSelector`,** because with `target-type: ip` the
ALB reaches pods from its own ENIs — which are not pods and therefore match no podSelector.

Probes are unaffected: the kubelet dials from the node, not pod-to-pod.

> ⚠️ **These policies do not permit `vprofile → vault` egress.** Wiring the application to Vault
> at runtime requires adding that rule first.

---

## 9. CI/CD

### Two pipelines

| | `Jenkinsfile` | `Jenkinsfile-platform` |
|---|---|---|
| Trigger | Push | **Manual only** — no `triggers` block |
| Identity | `jenkins-ec2-role` | Assumes `jenkins-platform-role` |
| EKS scope | namespace `vprofile` | cluster-wide |
| Frequency | Every commit | Once per cluster |
| On failure | One build | A half-built cluster |
| Length | 611 lines, 10 stages | 234 lines, 5 stages |

### Application pipeline — stage by stage

#### 1. Init
- **Purpose:** establish identity of this build
- **Input:** Git commit, `BUILD_NUMBER`, AWS account
- **Process:** resolve short SHA, compose `IMAGE_TAG`, derive `ECR_REGISTRY` from `sts:GetCallerIdentity`
- **Output:** `IMAGE_TAG`, `ECR_REGISTRY`
- **Fails if:** AWS credentials unavailable

#### 2. Maven Verify
- **Purpose:** compile and unit-test before anything is containerised
- **Process:** `mvn verify` with a bounded heap (`MAVEN_HEAP`), `SKIP_TESTS` available
- **Output:** WAR + JUnit results (9 tests)
- **Fails if:** compilation or any test fails
- **Protects against:** broken code reaching an image

#### 3. SonarQube
- **Purpose:** static analysis
- **Process:** scanner → local SonarQube; if `SONAR_GATE=true`, `sonarQualityGate()` blocks
- **Failure mode:** with the gate off, the analysis still runs but the verdict is downgraded to `UNSTABLE` via `catchError` — reported, not enforced
- **Note:** `SONAR_TOKEN` is passed as `-e SONAR_TOKEN` with no value on the command line, so it never appears in `ps` output

#### 4. Build
- **Purpose:** produce five images
- **Fails if:** any Dockerfile build fails
- **Note:** BuildKit is **not** active — the distro's `docker.io` package ships without the buildx plugin

#### 5. Trivy Scan
- **Purpose:** vulnerability scan + SBOM
- **Output:** `trivy-vprofile-*.txt` ×5 and `sbom-vprofile-*.cdx.json` ×5, archived per build
- **Position:** deliberately **before** ECR Login, so a vulnerable image never reaches the registry
- > ⚠️ **Current state:** `--exit-code 1` is absent from the scan invocation. `SECURITY_GATE` defaults to `true` and its description reads `ENFORCED`, but findings are reported without failing the build. **The code and the documentation disagree.** See the audit.

#### 6. ECR Login
- **Process:** `aws ecr get-login-password | docker login`

#### 7. Tag / 8. Push
- **Output:** five images at `<git-sha>-<build>`; `latest` only if `PUSH_LATEST=true`

#### 9. Verify
- **Purpose:** confirm each manifest actually exists in ECR
- **Why:** a push can report success while a manifest is missing; this catches it before deploy

#### 10. Deploy
- **Process:** `preflight()` → `renderManifests()` → `deployRelease()` → `verifyRollout()` → `smokeTest()`
- `helm upgrade --install --atomic` with `--set image.registry`, `image.tag`, `db.existingSecret`, `rabbitmq.existingSecret`
- The rendered manifest is archived as `rendered-<sha>-<build>.yaml` — every release is auditable after the fact
- **Fails if:** either Secret is missing (preflight), the chart fails to render, or the rollout does not become ready within `HELM_TIMEOUT`

#### Post
Unconditional cleanup: image removal, `docker image prune`, `docker builder prune`, and
`docker logout` — so ECR credentials do not persist on a shared build host between builds.

### Platform pipeline

```
Assume Platform Role  →  Connect  →  Report  →  Approval  →  Deploy
```

- **Assume Platform Role** — `sts:assume-role` with session name `jenkins-platform-<build>`, recorded in CloudTrail; asserts the resulting ARN contains `jenkins-platform` before proceeding
- **Report** — read-only inventory of helm releases, StorageClasses and namespace pod counts. Runs for both actions, so a `deploy` run captures a before-picture
- **Approval** — `input` gate, skippable via `REQUIRE_APPROVAL`
- **Deploy** — literally `bash platform/bootstrap-addons.sh`

**`ACTION` defaults to `verify`, not `deploy`** — an accidental "Build with Parameters" changes
nothing.

**There is no component picker, deliberately.** Ordering and prerequisites live in the script,
enforced by `set -euo pipefail` plus four explicit guards. A picker would split dependency logic
across two files and let a user reach step 5 without step 2.

---

## 10. Code Quality & Security

| Control | Status | Detail |
|---|---|---|
| SonarQube | ✅ Implemented | 26.8.0 community, self-hosted, loopback-bound, quality gate available |
| Trivy scanning | ✅ Implemented | Per-image, before registry push |
| Trivy **gate** | ⚠️ **Not enforcing** | `--exit-code 1` absent |
| SBOM | ✅ Implemented | CycloneDX ×5 per build |
| IAM least privilege | ✅ Implemented | Namespace-scoped CI role + assumable platform role |
| Kubernetes RBAC | ✅ Implemented | EKS access entries, namespace-scoped |
| NetworkPolicies | ✅ Implemented | 6 policies, enforcement enabled at CNI |
| Secrets | ✅ Implemented | Externally created; chart fails without them; KMS-encrypted at rest |
| Vault | ⚠️ Configured, not in runtime path | §11 |
| Container hardening | ✅ Partial | Contexts applied; `readOnlyRootFilesystem` pending |
| TLS | ❌ Not implemented | HTTP only |

---

## 11. Vault

### Deployed architecture

```
┌──────────── namespace: vault ─────────────┐
│                                           │
│   vault-0  (StatefulSet, 1 replica)       │
│   ├── Raft storage → 4 GiB gp3 PVC        │
│   ├── seal "awskms" → KMS auto-unseal     │
│   └── SA: vault  ──IRSA──► vprofile-vault │
│                                           │
│   vault-agent-injector (Deployment)       │
│   └── MutatingWebhookConfiguration        │
└───────────────────────────────────────────┘
```

### Key configuration decisions

**Raft, not the chart's default `file` backend.** Only Raft supports
`vault operator raft snapshot` — the sole correct way to back up Vault. An EBS snapshot of a live
Vault volume is not a Vault backup, for the same reason it is not a MySQL backup.

**KMS auto-unseal.** Vault starts *sealed*; its storage is encrypted with a master key it cannot
read until unsealed. Without auto-unseal, a human must paste key shares after **every** restart —
a node drain, an OOM kill, a chart upgrade. That is not operable. With `seal "awskms"`, Vault asks
KMS to decrypt its master key using the pod's IRSA identity.

The trade-off is explicit: the KMS key becomes a hard dependency of Vault starting at all. Hence
`deletion_window_in_days = 30` and rotation enabled.

**Single pod, not HA.** HA means 3 replicas with Raft consensus — roughly triple the memory, plus a
join sequence, demonstrating exactly the same concepts. The cost is real and stated: this Vault is
a single point of failure. Migration path: `server.ha.enabled=true`, 3 replicas; the seal stanza
and auth configuration carry over unchanged.

**`IPC_LOCK` is the one capability kept** from the `drop: ALL` — Vault mlocks its memory so secrets
never reach swap.

### Configured authentication chain

```
Pod runs as ServiceAccount app01 (namespace vprofile)
      ↓ presents projected SA token
Vault validates via Kubernetes TokenReview API
      ↓ matches bound_service_account_names + namespaces
Role vprofile-app → policy vprofile-app
      ↓
read on vprofile/data/app01 — 1-hour TTL token
```

**The policy, in full:**
```hcl
path "vprofile/data/app01" {
  capabilities = ["read"]
}
```

One path. Read only. **No `list`** — the holder cannot even enumerate what other secrets exist.

The role binds by `serviceaccount_uid`, not name: delete and recreate `app01` and it gets a new
UID, so a stale token cannot be replayed.

### Configuration process

`platform/vault-configure.sh` is **deliberately separate from CI and interactive**, because
`vault operator init` prints recovery keys and a root token exactly once. In a Jenkins log they
would persist on disk for 20 builds. The bootstrap script installs Vault and stops.

The bootstrap step also uses **no `--wait`**, unlike every other step — Vault's pod is not Ready
until initialised and unsealed, and cannot be initialised until it is Running. Waiting would
deadlock until timeout.

### ⚠️ Integration status — stated precisely

**The application does NOT read secrets from Vault.** It reads them from Kubernetes Secrets
(`db01-credentials`, `rmq01-credentials`). Verified: no `vault.hashicorp.com/*` annotations exist
in any chart template.

Vault is **installed, configured, populated and its authentication chain verified** — a
`vault write auth/kubernetes/login` with the `app01` token returned a token carrying
`token_policies ["default" "vprofile-app"]`. But it is not in the application's runtime path.

Completing the integration requires:
1. Vault Agent Injector annotations on the `app01` pod template
2. A NetworkPolicy egress rule permitting `vprofile → vault` (§8 — currently denied)
3. Accepting that Spring resolves placeholders at **startup**, so a rotated secret needs a pod restart regardless

Static KV secrets only. Dynamic database credentials — where Vault genuinely earns its cost — are
not implemented.

---

## 12. Monitoring & Observability

### Monitoring vs. observability in this project

**Monitoring** answers questions you knew to ask: is CPU high, are pods restarting, is a
node ready. This project has monitoring.

**Observability** is the property of being able to answer questions you did *not* anticipate,
usually requiring metrics, logs and traces correlated by request. This project has **one of the
three**. There is no log aggregation and no tracing, and the Java application exposes no
application-level metrics.

Calling this stack "observability" would overstate it. It is solid infrastructure monitoring.

### Deployed

`kube-prometheus-stack` 88.5.0:

| Component | Configuration |
|---|---|
| Prometheus | 7-day retention, `retentionSize: 8GiB`, 10 GiB gp3 |
| Grafana | 24 dashboards, `admin.existingSecret: grafana-admin`, 2 GiB, no Ingress |
| Alertmanager | 120h retention, 2 GiB |
| kube-state-metrics | Object state |
| node-exporter | DaemonSet, node OS metrics |

### The EKS-specific correction

```yaml
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeEtcd:              { enabled: false }
kubeProxy:             { enabled: false }

defaultRules:
  rules:
    etcd: false
    kubeControllerManager: false
    kubeSchedulerAlerting: false
    kubeProxy: false
```

On EKS the control plane is AWS-managed and unscrapeable. Left at their defaults, these produce
**four permanently-firing alerts and empty dashboard panels from the first minute**.

**Disabling the scrape target is only half the fix** — the alert rule groups are still created and
fire on absent metrics. Both halves are required.

### Cross-namespace discovery

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
```

Without this, Prometheus only discovers ServiceMonitors created by its own Helm release. With it,
a ServiceMonitor placed in the `vprofile` namespace is picked up automatically.

### ⚠️ Gaps

- **Alertmanager has no receivers.** Alerts fire and go nowhere. An alert nobody receives is not an alert.
- **No log aggregation** — no Loki, no Fluent Bit.
- **No application metrics** — infrastructure only.

---

## 13. Backup & Disaster Recovery

### The four-level distinction

```
Backup Configured  ≠  Backup Successful  ≠  Restore Tested  ≠  DR Validated
```

| Level | Status | Evidence |
|---|---|---|
| Configured | ✅ | `platform/values/velero.yaml`, `terraform/velero.tf` |
| Successful | ✅ | Backup `pre-test` reached `Completed`, 0 errors; objects present in S3 |
| Tested | ⚠️ | Restore executed → **`PartiallyFailed`**, 1 error, 4 warnings |
| Validated | ❌ | **Not achieved** |

### Architecture

```
Kubernetes objects ──┐
                     ├──► Velero ──IRSA──► S3 vprofile-velero-backups-<account>
EBS volumes ─────────┘         └──────────► EC2 CreateSnapshot
```

Velero 12.1.0 with a **mandatory** `velero-plugin-for-aws:v1.13.1` initContainer — the chart ships
no cloud plugin, and without it every backup fails with `unable to locate provider aws`.

`credentials.useSecret: false` is what switches Velero from reading a credentials file to using
its IRSA identity.

### What is backed up

| Schedule | Namespaces | Volumes | TTL |
|---|---|---|---|
| `daily-vprofile` | `vprofile` | ✅ snapshots | 30 days |
| `weekly-platform` | `monitoring`, `velero` | ❌ objects only | 14 days |

The platform namespaces hold nothing worth snapshotting — they are rebuildable from
`bootstrap-addons.sh`.

**Retention layering:** the S3 lifecycle expires objects at **35 days**, deliberately longer than
the 30-day Velero TTL. If S3 expired first, Velero would list backups that cannot restore.

### Application consistency

A pre-backup hook on the `db01` pod:

```
mysqldump --single-transaction --routines --triggers --databases <db>
  > /var/lib/mysql/backup/dump.sql
```

**Why a dump and not `FLUSH TABLES WITH READ LOCK`:** the lock releases the moment the hook's
session ends — which is *before* the snapshot is taken. It would produce no effect at all. This is
the common mistake. The dump writes a known-good logical export into the volume so the snapshot
captures both the datadir and the dump.

`on-error: Fail` is deliberate: a backup that silently skipped its consistency step is worse than
one that failed loudly.

### Restore test — actual result

```
velero restore create --from-backup pre-test --wait
Restore completed with status: PartiallyFailed

NAME                      BACKUP     STATUS           ERRORS  WARNINGS
pre-test-20260823015240   pre-test   PartiallyFailed  1       4
```

**What recovered:** the database PVC. `kubectl describe pvc data-db01-0` afterwards showed
`Status: Bound`, `Used By: db01-0`, and the labels `velero.io/backup-name=pre-test` and
`velero.io/restore-name=pre-test-20260823015240` — labels Velero applies only to objects it
restored.

**What is unknown:** the cause of the error, the content of the four warnings, and whether the
restored MySQL data is intact. `velero restore logs` was not captured, and no row count was run
before and after.

**Honest conclusion: disaster recovery is not validated.** Any claim otherwise would be
unsupported.

### Limitations

- Restore is `PartiallyFailed` with unknown root cause
- No data integrity verification after restore
- **Vault's own data is not backed up** — it needs `vault operator raft snapshot`, not an EBS snapshot, and no schedule exists
- Terraform state relies on S3 versioning alone
- Restore into a *fresh cluster* — the real DR scenario — was never attempted

---

## 14. Security Architecture

### Defence in depth, layer by layer

```
┌─ AWS IAM ──────────────────────────────────────────────────────┐
│  jenkins-ec2-role: SSM, ECR, eks:Describe, AssumeRole(1 ARN)    │
│         │ sts:AssumeRole (1h session, CloudTrail)               │
│         └──► jenkins-platform-role: EKS ClusterAdmin            │
│  4 IRSA roles — LB Controller, EBS CSI, Velero, Vault           │
├─ Network ──────────────────────────────────────────────────────┤
│  Private subnets · private cluster endpoint · SSM (no SSH)      │
│  Security groups · NAT egress only                              │
├─ Kubernetes RBAC ──────────────────────────────────────────────┤
│  EKS access entries: CI = Edit on `vprofile` only               │
│  5 per-workload ServiceAccounts, 4 with token automount off     │
├─ Pod networking ───────────────────────────────────────────────┤
│  6 NetworkPolicies, default-deny, CNI enforcement enabled       │
├─ Workload ─────────────────────────────────────────────────────┤
│  drop ALL · no privilege escalation · seccomp RuntimeDefault    │
├─ Secrets ──────────────────────────────────────────────────────┤
│  KMS-encrypted at rest · none in Git · Vault with 1-path policy │
└─ Supply chain ─────────────────────────────────────────────────┘
   Trivy pre-push · CycloneDX SBOM · commit-SHA tags · .trivyignore
```

### The AssumeRole boundary

The single most important security decision:

- **What it prevents:** the application pipeline cannot touch `kube-system`, `vault`, `monitoring` or `velero` — even if `Jenkinsfile` is modified — because its role simply lacks the access.
- **What it provides:** attribution. CloudTrail records an `AssumeRole` event with session name `jenkins-platform-<build>`.
- **What it does NOT prevent:** anyone who can commit to `Jenkinsfile-platform` can assume the role. **Branch protection is not configured** — that is the control which closes this gap, and it is a GitHub setting, not code.

### ClusterAdmin on the platform role — why it is not narrower

`AmazonEKSAdminPolicy` maps to the Kubernetes `admin` ClusterRole, which is **namespace-scoped**
and excludes CustomResourceDefinitions, ClusterRoles and webhook configurations — all three of
which the add-on charts create. Narrowing it would mean hand-maintaining a ClusterRole mirroring
five upstream charts' RBAC and re-auditing it on every version bump.

**The isolation is the separate assumed role, not a reduced policy.** The power exists only inside
a one-hour session, never as a standing grant.

---

## 15. Deployment Workflow

```
1. terraform apply
      VPC · EKS · ECR · Jenkins EC2 · IAM · S3 · KMS
      ↓
2. Platform pipeline (ACTION=deploy) → bootstrap-addons.sh
      1/6 vprofile namespace
      2/6 gp3 StorageClass (gp2 demoted)
      3/6 AWS Load Balancer Controller
      4/6 kube-prometheus-stack        ← requires grafana-admin Secret
      5/6 Velero                       ← requires the S3 bucket
      6/6 Vault                        ← requires the KMS alias
      ↓
3. Create application Secrets  (db01-credentials, rmq01-credentials)
      ↓
4. Vault init + vault-configure.sh     ← interactive, human only
      ↓
5. Application pipeline → ALB → application live
```

**Ordering is enforced, not documented.** `set -euo pipefail` plus four explicit `exit 1` guards
mean step 5 cannot run if step 3 failed, and each guard prints the exact command to fix it.

**Dependency chain:** `gp3` StorageClass must precede monitoring, Velero and Vault — all three
provision PVCs against it. The ALB Controller must precede any Ingress, or the Ingress is accepted
and no ALB is ever created.

---

## 16. Troubleshooting & Real Problems Solved

### Problem 1 — HTTP 403 on user registration

**What happened.** The application deployed successfully, pods were Ready, the login page rendered
— and every registration attempt returned 403.

**Root cause.** Three stacked causes, each of which alone would have caused a failure:

1. **Session affinity.** VProfile stores sessions in memory. With 2 `app01` replicas and no affinity, the CSRF token issued by pod A was validated by pod B, which had never seen it.
2. **Hibernate 4 → 5.** `GenerationType.AUTO` changed behaviour on MySQL, expecting a `hibernate_sequence` table that the schema does not contain.
3. **A misleading diagnostic.** The `curl` used to investigate hit the *Service* (load-balancing across 2 pods) rather than a single pod via port-forward — so the test reproduced the affinity bug while attempting to isolate a different one.

**Solution.**
- ALB `target-group-attributes: stickiness.enabled=true` **and** `sessionAffinity: ClientIP` on the `app01` Service. Both are load-bearing: nginx has one ClusterIP upstream, so kube-proxy handles the second hop.
- `GenerationType.IDENTITY` on `User.java` and `Role.java`.
- Diagnostics rerun via `port-forward` to a single pod.

**Lesson.** When three faults stack, fixing one changes the symptom without fixing the problem —
which reads as "the fix didn't work" and sends you down the wrong path. Isolate each layer with a
test that can only fail for one reason. And **verify your diagnostic tool tests what you think it
tests** before trusting its output.

---

### Problem 2 — `kubectl` succeeded while returning Forbidden

**What happened.** The pipeline's preflight check printed `Forbidden` in red and the build
continued as though the cluster were reachable.

**Root cause.**
```bash
kubectl get nodes --no-headers | awk '{print $1}'
```
In a pipeline, the exit status of a pipeline is the exit status of its **last** command. `awk`
succeeded on empty input, so `kubectl`'s non-zero exit was discarded. A hard failure was invisible.

Compounding it, `get nodes` is **cluster-scoped** — outside the namespace-scoped
`AmazonEKSEditPolicy` the CI role holds. The check could never have passed under the final access
design.

**Solution.** Replaced with a namespace-scoped check capturing the status explicitly:
```groovy
def rc = sh(returnStatus: true, script: "kubectl -n ${ns} get pods > /dev/null 2>&1")
```

**Lesson.** Piping a command into a filter destroys its exit status. In CI this converts a hard
failure into a silent one, which is strictly worse than a loud failure. And a connectivity check
must use an operation the caller is actually permitted to perform.

---

### Problem 3 — Namespaces stuck `Terminating` during teardown

**What happened.** `kubectl delete namespace` hung for a long time on all four namespaces.

**Root cause.** The Helm releases were uninstalled **before** the namespaces were deleted. That
removed the Velero and Prometheus Operator controllers — the very controllers responsible for
clearing the finalizers on their own custom resources. A `restores.velero.io` object retained
`velero.io/external-resources-finalizer` with nothing left running to remove it.

**Solution.** Cleared the namespace finalizers directly:
```bash
kubectl get ns "$ns" -o json | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
```

**Lesson.** Uninstall order matters in reverse. A controller that owns finalizers must outlive the
objects it finalizes. When tearing down, delete the custom resources first, then the controller —
or accept that you will force-clear finalizers.

---

### Problem 4 — `helm --create-namespace` failed with Forbidden

**What happened.** The Deploy stage failed on namespace creation despite the namespace existing.

**Root cause.** `--create-namespace` performs a **GET on the Namespace object**, which is
cluster-scoped. Under `AmazonEKSEditPolicy` scoped to one namespace, that read is denied — even
when the namespace is already there.

**Solution.** Removed the flag; namespace creation moved to `bootstrap-addons.sh` step 1/6, which
runs under the platform role.

**Lesson.** Least privilege surfaces in unexpected places. A convenience flag can require a
permission far broader than the operation appears to need. When you scope a role down, expect to
find these one at a time — and prefer discovering them in a guard than in a deploy.

---

### Problem 5 — Terraform state bucket deleted before destroy completed

**What happened.** `terraform destroy` failed with `NoSuchBucket` and Terraform lost its entire
resource map.

**Root cause.** The S3 state backend bucket was deleted manually from the console while
infrastructure still existed.

**Solution.** Remaining resources were removed manually in dependency order — EKS node group,
cluster, EC2, ALBs, NAT gateways, Elastic IPs, EBS volumes and snapshots, ECR, KMS, then the VPC.
The account was verified clean by an audit script covering every billable resource type.

**Lesson.** **The state file is the map. Delete it last, never first.** A destroy that has already
progressed partway leaves an inconsistent environment that Terraform can no longer reason about.
In any shared environment, the state bucket should carry MFA-delete or a deletion policy.

---

### Problem 6 — Vault reported sealed while it was demonstrably unsealed

**What happened.** `vault-configure.sh` aborted with "Vault is initialised but SEALED", while
`vault status` run manually seconds later showed `Sealed: false`.

**Root cause.** The script's status parsing:
```bash
status="$(vex vault status -format=json 2>/dev/null || true)"
sealed="$(printf '%s' "$status" | jq -r '.sealed // true')"
```
`2>/dev/null` swallowed the real error, and `// true` defaulted to *sealed* when `status` was
empty. The likely trigger was `jq` being unavailable — producing an empty string, which the
fallback interpreted as the failure state.

**Solution.** Ran the four configuration steps directly. The pending fix is to stop suppressing
stderr, assert `jq` exists, and add a retry loop for the auto-unseal window.

**Lesson.** A defensive default that fails *closed* is correct — but only if the check can
distinguish "sealed" from "I could not tell". Conflating "unknown" with "bad" produces false
alarms that erode trust in the guard, which is how guards end up being bypassed.

---

### Problem 7 — Vault authentication returned `permission denied`

**What happened.** `vault write auth/kubernetes/login` returned 403 despite a correct role and
policy.

**Root cause.** The Kubernetes auth config was written with single quotes:
```bash
vault write auth/kubernetes/config \
  kubernetes_host='https://$KUBERNETES_PORT_443_TCP_ADDR:443'
```
Single quotes correctly prevented expansion on the *host* — the variable is meant to resolve
inside the pod. But `vault write` is not a shell: it stored the string **literally**, including the
`$`. Vault then tried to reach a hostname that does not exist.

**Solution.** Wrapped in `sh -c` so the variable expands inside the pod:
```bash
kubectl -n vault exec -i vault-0 -- sh -c '
  vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
```

Verified: login returned a token with `token_policies ["default" "vprofile-app"]` and
`token_meta_service_account_namespace: vprofile`.

**Lesson.** When a command crosses a boundary — host shell → `kubectl exec` → container →
application — you must know *which* layer performs expansion. Quoting that is correct at one layer
is wrong at another, and the failure surfaces far from its cause.

---

## 17. Production Considerations

**Current implementation** and **recommended improvements** kept strictly separate. Nothing below
the line is implemented.

| Area | Current | Recommended for production |
|---|---|---|
| **Database** | MySQL StatefulSet, 1 replica, in-cluster | **RDS MySQL Multi-AZ** — automated failover, PITR, patching, backups |
| **Cache** | Memcached container | ElastiCache |
| **Messaging** | RabbitMQ container | Amazon MQ |
| **TLS** | ❌ HTTP only | ACM certificate + Route 53 + HTTPS listener + HTTP→HTTPS redirect |
| **Vault** | Single pod | 3-replica Raft HA; `server.ha.enabled=true` |
| **Vault integration** | Not in runtime path | Agent Injector annotations + `vprofile→vault` NetworkPolicy + dynamic DB credentials |
| **Alerting** | ❌ No receivers | PagerDuty/Slack/SNS receivers + routing tree + escalation |
| **Logs** | ❌ None | Loki or OpenSearch + Fluent Bit |
| **Tracing** | ❌ None | OpenTelemetry + X-Ray or Jaeger |
| **App metrics** | ❌ None | JMX exporter or Micrometer + a ServiceMonitor |
| **Security gate** | ⚠️ Reports only | Restore `--exit-code 1`; manage exceptions in `.trivyignore` |
| **Container FS** | Writable root | `readOnlyRootFilesystem: true` + emptyDir for Tomcat work/temp, nginx cache, MySQL datadir |
| **Branch protection** | ❌ None | Required reviews on `Jenkinsfile-platform` — currently commit access equals platform access |
| **DR** | Restore PartiallyFailed | Diagnose the error; scheduled restore drills into a fresh cluster; document RTO/RPO |
| **Vault backup** | ❌ None | Scheduled `vault operator raft snapshot` to S3 |
| **State protection** | S3 versioning | MFA-delete or bucket deletion policy |
| **Cost** | 3 NAT (~$3.46/day) | Keep for prod; `single_nat_gateway` for dev/staging |
| **Environments** | One cluster | Separate dev/staging/prod accounts with promotion |
| **GitOps** | Push-based Jenkins | Argo CD or Flux for drift detection and reconciliation |

---

## 18. Lessons Learned

**1. Test the assumption before designing around it.**
The umbrella-chart decision was initially made on a *belief* about how Helm handles namespaces.
Testing it disproved the belief — but revealed a different, real constraint (three of four charts
hardcode `.Release.Namespace`) that pointed to the same conclusion for a better reason. The
conclusion survived; the reasoning had to be replaced.

**2. Silent failures are the expensive ones.**
Three separate problems in this project were failures that *looked like success*: a `kubectl`
exit status destroyed by a pipe, a NetworkPolicy accepted but not enforced, a security gate whose
description says ENFORCED while its flag is absent. Each was harder to find than an outright crash.
Design checks to fail loudly.

**3. Least privilege is discovered incrementally, not designed up front.**
Scoping the CI role to one namespace broke `helm --create-namespace`, `kubectl get nodes`, and
manual Secret creation — none of which was predicted. Each break was a correct signal. The cost of
least privilege is these interruptions; the benefit is that a compromised build cannot read Vault.

**4. An untested backup is a hypothesis.**
The restore was run and it partially failed. That is a *better* outcome than not running it,
because the risk is now known rather than assumed away. Documenting `PartiallyFailed` honestly is
worth more than a green backup screenshot.

**5. Know which layer expands your variables.**
The Vault `kubernetes_host` bug crossed four boundaries. Quoting correct at one was wrong at
another, and the error surfaced as an unrelated 403 during authentication.

**6. Ordering is a property of the system, not the documentation.**
Dependencies enforced by `set -euo pipefail` and explicit guards cannot be bypassed. Dependencies
written in a README can. This is why the platform pipeline has no component picker.

**7. State is the map.**
Deleting the Terraform state bucket mid-teardown turned a routine `destroy` into hours of manual
cleanup. Destroy first, verify, then remove the backend.

---

## 19. Final Architecture

See [`docs/architecture/`](architecture/) for seven layered diagrams:

| # | Diagram | Layer |
|---|---|---|
| 01 | High-level | Developer → GitHub → Jenkins → AWS → EKS |
| 02 | AWS infrastructure | VPC, AZs, subnets, IGW, NAT, ALB, EKS, ECR, S3, KMS |
| 03 | Kubernetes | Nodes, namespaces, workloads, services, ingress, storage |
| 04 | CI/CD pipeline | Both pipelines with their identity boundary |
| 05 | Monitoring | Metric flow from exporters to Grafana |
| 06 | Security & secrets | IAM, AssumeRole, IRSA, Vault, NetworkPolicies |
| 07 | Backup & DR | Velero → S3 + EBS snapshots, restore path |

---

# Documentation Audit

## Implemented — built, deployed and verified working

```
✅ 3-AZ VPC, 6 subnets, 3 NAT gateways, private/public split
✅ EKS 1.34, private endpoint, 3 managed nodes, KMS secret encryption
✅ vpc-cni with NetworkPolicy enforcement enabled
✅ 5 ECR repositories with lifecycle policies
✅ Jenkins EC2 with SonarQube, provisioned by user-data, SSM access
✅ Application pipeline — 10 stages + Deploy, 10 successful builds
✅ Multi-stage Docker build; 5 images; commit-SHA tagging
✅ Helm chart — 25 objects, kubeconform 1.34 strict 25/25
✅ 6 NetworkPolicies · 3 PDBs · 5 per-workload ServiceAccounts
✅ Container security contexts on all 6 containers
✅ AWS Load Balancer Controller + working ALB
✅ EBS CSI + gp3 default StorageClass
✅ kube-prometheus-stack — 24 dashboards, all 5 namespaces scraped
✅ Velero — backup Completed, objects confirmed in S3
✅ Vault — Raft, KMS auto-unseal, K8s auth verified by a login test
✅ AssumeRole separation between application and platform pipelines
✅ Application serving authenticated, database-backed sessions
```

## Configured but not fully validated

```
⚠️  Trivy SECURITY_GATE   — parameter says ENFORCED; --exit-code 1 is absent,
                            so findings report without failing the build.
                            CODE AND DOCUMENTATION DISAGREE — highest-priority fix.

⚠️  Vault integration     — installed, configured, populated, auth chain verified.
                            NOT in the application's runtime path: no injector
                            annotations, and NetworkPolicy denies vprofile→vault.

⚠️  Velero restore        — executed, returned PartiallyFailed (1 error, 4 warnings).
                            Database PVC recovered and bound. Root cause not captured,
                            data integrity not verified. DR IS NOT VALIDATED.

⚠️  Alertmanager          — deployed with no receivers. Alerts fire and are not delivered.

⚠️  Vault auto-unseal     — configured as awskms; observed working, not captured as evidence.

⚠️  EKS control plane logs — 5 log types enabled; no CloudWatch dashboard or metric filter
                            consumes them.
```

## Unused / legacy

```
📦 archive/PATCHES/                10 historical patch files. Reference only —
                                   all already applied. Not part of the build.

🚫 Elasticsearch                   Referenced in the VProfile UI navigation but REMOVED
                                   during image hardening. The link is a UI remnant.
                                   Not deployed. Not part of the architecture.

🚫 RDS / ElastiCache / Amazon MQ   Never used. All three data services run in-cluster.

🚫 Route 53 / ACM                  Not used. No DNS zone, no certificate, no TLS.

🚫 readOnlyRootFilesystem          Discussed and scoped; not implemented.

⚙️  PARALLEL parameter             Present in the Jenkinsfile; not exercised in the
                                   builds captured as evidence.
```

## Recommended future improvements

Priority order, highest first:

```
1.  Restore --exit-code 1 to the Trivy gate, or change the parameter description
    and default to match reality. A control that claims to enforce and does not is
    worse than one honestly labelled advisory.

2.  Diagnose the Velero restore failure:
      velero restore logs pre-test-20260823015240
    then re-run with a row count before and after.

3.  Configure Alertmanager receivers. Dashboards nobody watches at 3am are not alerting.

4.  Complete the Vault integration: injector annotations + vprofile→vault NetworkPolicy.

5.  Add TLS: ACM certificate, Route 53 record, HTTPS listener, HTTP→HTTPS redirect.

6.  Enable branch protection on Jenkinsfile-platform. Commit access currently equals
    platform access.

7.  Schedule vault operator raft snapshot to S3. Vault's own data has no backup.

8.  Add readOnlyRootFilesystem, component by component.

9.  Migrate the database to RDS Multi-AZ. The current single StatefulSet replica is
    the largest availability risk in the architecture.

10. Add log aggregation — the missing third of observability.
```

---

*Guide compiled from repository commit `48e113d`. Every claim traceable to a tracked file.*
