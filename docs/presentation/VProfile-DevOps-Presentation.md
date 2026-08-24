# VProfile DevSecOps Platform — Presentation Outline

**15 slides.** Designed for a 12–15 minute technical walkthrough, a portfolio review, or an
interview. Screenshot IDs refer to `docs/SCREENSHOTS.md`.

**Design rules applied:** one idea per slide · at most one screenshot per slide · no slide is a
wall of text · limitations are stated on the slide, not hidden in speaker notes.

---

## Slide 1 — Title

> **VProfile DevSecOps Platform on Amazon EKS**
> Terraform · Jenkins · Kubernetes · Vault · Prometheus · Velero
>
> ALnaqib — DevOps Engineer

*Visual:* the high-level architecture diagram, faded, as a background.

---

## Slide 2 — Project Overview

**What:** a five-tier Java application deployed to Amazon EKS with everything defined as code.

| | |
|---|---|
| Application | nginx → Tomcat → MySQL + Memcached + RabbitMQ |
| Infrastructure | 3-AZ VPC, private EKS 1.34, all Terraform |
| Delivery | Jenkins — build, analyse, scan, SBOM, push, deploy |
| Platform | Monitoring, backup, secrets management |

*Speaker note:* the application is not the point — the platform around it is. VProfile was chosen
because it has genuine multi-tier dependencies that break in interesting ways.

---

## Slide 3 — Engineering Goals

```
Reproducible     rebuild from code, no undocumented manual steps
Least privilege  no component holds more access than it needs
Observable       know the state before problems occur
Recoverable      backups off-cluster, and the restore path exercised
Cost-bounded     destroy and rebuild to control spend
```

**Explicit non-goals:** platform HA · TLS · multi-environment promotion.

*Speaker note:* naming non-goals up front prevents the "why no TLS?" question landing as a gap
rather than a decision.

---

## Slide 4 — High-Level Architecture

*Visual:* diagram 01.

```
Developer → GitHub → Jenkins → ECR → EKS → ALB → User
```

**One line to land:** Jenkins and the nodes are in private subnets; the EKS endpoint is
private-only. The ALB is the sole internet-facing component.

---

## Slide 5 — AWS Infrastructure

*Visual:* **SS-010** (VPC resource map) + **SS-012** (3 NAT gateways).

| | |
|---|---|
| VPC | `10.0.0.0/16`, 3 AZs |
| Subnets | 3 public + 3 private, `/24` each |
| NAT | One per AZ — zone-redundant egress |
| EKS | 1.34, private endpoint, 3 nodes |

**The trade-off to say out loud:** three NAT gateways cost ~$3.46/day versus $1.15 for one.
Availability over cost — and I would choose differently for a dev environment.

*Why these screenshots:* the resource map reads instantly; NAT ×3 opens a question I can answer
in both directions.

---

## Slide 6 — Kubernetes

*Visual:* **SS-031** (3 nodes Ready + system pods).

```
5 namespaces   vprofile · monitoring · velero · vault · kube-system
25 objects      from the application Helm chart
6 NetworkPolicies · 3 PDBs · 5 per-workload ServiceAccounts
```

**Point to make:** `EXTERNAL-IP <none>` and the `10.0.1x.x` addresses prove the nodes are private.
Zero restarts across every system pod means a clean start, not a crash-loop that settled.

*Why terminal over console:* it is more credible evidence that something is actually running.

---

## Slide 7 — CI/CD Pipeline

*Visual:* **SS-020** (11 stages, all green, with the Deploy stage).

```
Init → Maven → SonarQube → Build → Trivy+SBOM → ECR → Tag → Push → Verify → Deploy
```

**Two details worth naming:**
- Trivy runs **before** ECR login — a vulnerable image never reaches the registry
- Five CycloneDX SBOMs archived per build — the artifact you need when the next Log4Shell lands

*Why this screenshot:* the most information-dense frame in the project.

---

## Slide 8 — Iteration ⭐

*Visual:* **SS-022** (builds #1 and #2 failed, #3 green).

**Deliberately included.**

```
Failure → Investigation → Fix → Verification
```

The failure cascade is correct: when SonarQube fails, every downstream stage fails rather than
skipping. That is the pipeline working as designed.

*Speaker note:* every portfolio has green checkmarks. Showing the failure next to the fix
demonstrates the debugging loop, which is the actual job.

---

## Slide 9 — Security & Least Privilege

*Visual:* the AssumeRole flow from diagram 06.

```
jenkins-ec2-role       EKSEditPolicy → namespace vprofile ONLY
        │ sts:AssumeRole (1h, CloudTrail)
        └─► jenkins-platform-role   ClusterAdmin
```

| Control | |
|---|---|
| 2 Jenkins roles, one assumable | Platform power is borrowed, never standing |
| 4 IRSA roles | No static AWS keys anywhere |
| 6 NetworkPolicies | Default-deny, enforcement on at the CNI |
| Trivy + SBOM | Supply chain |

**State the gap:** branch protection is not configured — commit access to
`Jenkinsfile-platform` currently equals platform access.

---

## Slide 10 — Vault / Secrets

*Visual:* **SS-043** (policy HCL) + **SS-044** (auth role binding).

```hcl
path "vprofile/data/app01" {
  capabilities = ["read"]
}
```

One path. Read only. **No `list`** — the holder cannot even enumerate other secrets.

```
SA app01 (ns vprofile) → TokenReview → role → policy → 1h token
```

**State the gap:** Vault is configured, populated and its auth chain verified — but the
application still reads from Kubernetes Secrets. Not yet in the runtime path.

*Why these two together:* the claim and its enforcement, side by side.

---

## Slide 11 — Monitoring

*Visual:* **SS-050** (Grafana, all five namespaces).

```
kube-state-metrics ┐
node-exporter      ├→ Prometheus (7d) → Grafana (24 dashboards)
kubelet/cAdvisor   ┘
```

**The EKS-specific fix:** `kubeEtcd`, `kubeControllerManager`, `kubeScheduler` and `kubeProxy`
scraping **and their alert rules** disabled — AWS manages them and they are unscrapeable. Left on,
they produce four permanently-firing alerts from minute one.

**Caption precisely:** metrics, not alerting. Alertmanager has no receivers.

---

## Slide 12 — Backup & Disaster Recovery ⭐

*Visual:* **SS-060** (backup Completed) **and** **SS-062** (restore PartiallyFailed).

```
Backup Configured ✅  ≠  Backup Successful ✅  ≠  Restore Tested ⚠️  ≠  DR Validated ❌
```

The restore ran. It returned **PartiallyFailed** — 1 error, 4 warnings. The database PVC
recovered and bound. The root cause was not captured.

**What I would do next:**
```bash
velero restore logs pre-test-20260823015240
# and SELECT COUNT(*) before and after
```

*Speaker note:* presenting only the backup would misrepresent the state. An untested backup is a
hypothesis; a partially-tested one is a known risk. Both beat an unqualified claim.

---

## Slide 13 — The Application

*Visual:* **SS-001** (authenticated user session through the ALB).

**The payoff slide.** Everything before it existed to produce this.

Client → ALB → nginx → Tomcat → MySQL, with a session that survived — which required fixing
three stacked causes of a 403 on registration.

---

## Slide 14 — Technology Stack

| Layer | Tools |
|---|---|
| Cloud | AWS `eu-west-3` |
| IaC | Terraform ≥1.10, S3 backend |
| Containers | Docker multi-stage, ECR ×5 |
| Orchestration | EKS 1.34, Helm, ALB Controller, EBS CSI |
| CI/CD | Jenkins, Maven |
| Security | SonarQube, Trivy, Vault, NetworkPolicies |
| Monitoring | Prometheus, Grafana, Alertmanager |
| Backup | Velero → S3 + EBS snapshots |

**Not used:** RDS · ElastiCache · Amazon MQ · Route 53 · ACM. All data services run in-cluster.

---

## Slide 15 — Results & Lessons

**Delivered**
```
✅ 3-AZ private EKS platform, fully in Terraform
✅ 11-stage pipeline: build → analyse → scan → SBOM → push → deploy
✅ Working application serving authenticated, DB-backed sessions
✅ Monitoring across 5 namespaces · Backups to S3 with EBS snapshots
✅ Vault with namespace-scoped, single-path secret access
✅ Privilege separation between application and platform delivery
```

**Lessons**
1. **Test the assumption before designing around it** — the umbrella-chart belief was wrong; testing found a better reason for the same conclusion
2. **Silent failures are the expensive ones** — three bugs here looked like success
3. **Least privilege is discovered incrementally** — scoping the role broke four things, each correctly
4. **An untested backup is a hypothesis** — so I tested it, and it partially failed
5. **State is the map** — deleting it mid-teardown turned a `destroy` into hours of manual cleanup

---

## Screenshots used — 8 of 31

```
SS-001  Application running                 Slide 13
SS-010  VPC resource map                    Slide 5
SS-012  NAT gateways ×3                     Slide 5
SS-020  Pipeline 11 stages                  Slide 7
SS-022  Failed builds                       Slide 8
SS-031  Nodes + system pods                 Slide 6
SS-043  Vault policy HCL                    Slide 10
SS-044  Vault auth role                     Slide 10
SS-050  Grafana all namespaces              Slide 11
SS-060  Velero backup Completed             Slide 12
SS-062  Velero restore PartiallyFailed      Slide 12
```

**Deliberately excluded:** SS-002 (duplicate of SS-001) · SS-011 / SS-013 (detail without a
story) · SS-016 (weak) · SS-024 (P4, superseded) · SS-042 / SS-053 (list views) · SS-051 / SS-052
(SS-050 covers the same ground in one frame).

---

## Delivery notes

| Slide | Time | Emphasis |
|---|---|---|
| 1–3 | 2 min | Context and goals — move quickly |
| 4–6 | 3 min | Architecture — the private-endpoint decision |
| 7–8 | 3 min | Pipeline, then the failure slide |
| 9–10 | 3 min | Security — the AssumeRole boundary is the strongest idea |
| 11–12 | 2 min | Monitoring gap, then DR honestly |
| 13–15 | 2 min | Payoff and lessons |

**The two slides that differentiate this deck are 8 and 12** — the ones showing what failed. Do
not cut them for time; cut slide 14 instead.
