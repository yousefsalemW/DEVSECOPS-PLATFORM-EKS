# Diagram 03 — Kubernetes Architecture

Workloads and namespaces. The application namespace renders 25 objects from the Helm chart.

```mermaid
flowchart TB
    ALB["ALB<br/>target-type: ip"]

    subgraph CLUSTER["EKS vprofile-eks · 3 nodes · 1.34"]
        direction TB

        subgraph NSAPP["namespace: vprofile"]
            direction TB
            ING["Ingress<br/>class: alb · stickiness on"]
            WEB["vproweb · Deployment ×2<br/>nginx:1.27-alpine"]
            APPD["app01 · Deployment ×2<br/>tomcat 9 + JRE11<br/>sessionAffinity: ClientIP"]
            DB["db01 · StatefulSet ×1<br/>mysql:8.0.43"]
            MC["mc01 · Deployment ×1<br/>memcached"]
            RMQ["rmq01 · Deployment ×1<br/>rabbitmq"]
            PVC[("PVC data-db01-0<br/>8 GiB gp3")]

            ING --> WEB
            WEB -->|:8080| APPD
            APPD -->|:3306| DB
            APPD -->|:11211| MC
            APPD -->|:5672| RMQ
            DB --- PVC
        end

        subgraph NSMON["namespace: monitoring"]
            PROM["Prometheus<br/>7d · 10 GiB"]
            GRAF["Grafana<br/>24 dashboards"]
            AM["Alertmanager<br/>⚠ no receivers"]
        end

        subgraph NSVEL["namespace: velero"]
            VEL["Velero + AWS plugin"]
        end

        subgraph NSVAULT["namespace: vault"]
            VAULT["vault-0<br/>Raft · KMS unseal"]
            INJ["Agent Injector<br/>⚠ not wired to app"]
        end

        subgraph NSSYS["namespace: kube-system"]
            LBC["ALB Controller 1.13.4"]
            CSI["EBS CSI driver"]
            DNS["CoreDNS · kube-proxy · vpc-cni"]
        end
    end

    ALB --> ING
    LBC -.->|provisions| ALB
    CSI -.->|provisions| PVC
    PROM -.->|scrapes| NSAPP
    PROM --> GRAF

    classDef app fill:#e3f2fd,stroke:#1976d2,color:#0d47a1
    classDef plat fill:#f3e5f5,stroke:#8e24aa,color:#4a148c
    classDef sys fill:#eceff1,stroke:#546e7a,color:#263238
    classDef warn fill:#fff3e0,stroke:#ef6c00,color:#e65100
    class WEB,APPD,DB,MC,RMQ,ING,PVC app
    class PROM,GRAF,VEL,VAULT plat
    class LBC,CSI,DNS sys
    class AM,INJ warn
```

## Chart object inventory — 25 objects

| Kind | Count | Names |
|---|---|---|
| ServiceAccount | 5 | `app01` `db01` `mc01` `rmq01` `vproweb` |
| Deployment | 4 | `app01`(2) `vproweb`(2) `mc01`(1) `rmq01`(1) |
| StatefulSet | 1 | `db01`(1) |
| Service | 5 | one per workload |
| Ingress | 1 | ALB |
| PodDisruptionBudget | 3 | `app01` `vproweb` `db01` |
| NetworkPolicy | 6 | see below |

## NetworkPolicies

```
default-deny        deny all ingress AND egress
allow-dns           egress → kube-system DNS
vproweb-ingress     ingress from ipBlock 10.0.0.0/16   ← ALB uses ENIs, not pods
vproweb-egress      egress → app01:8080
app01               ingress from vproweb; egress → db01/mc01/rmq01 only
backends-ingress    accept only from app01, no egress beyond DNS
```

Enforcement is active because `vpc-cni` is configured with `enableNetworkPolicy = "true"`.
Without it, policies are accepted and displayed but **never enforced**.

## PodDisruptionBudgets

| PDB | minAvailable | Effect |
|---|---|---|
| `app01` | 1 of 2 | Survives node drain |
| `vproweb` | 1 of 2 | Survives node drain |
| `db01` | 1 of 1 | **Deliberately blocks drain** — a single-replica DB should not be evicted silently |

## Storage

`gp3` is the default StorageClass; `gp2` is demoted by `bootstrap-addons.sh`.

| PVC | Size | Owner |
|---|---|---|
| `data-db01-0` | 8 GiB | MySQL |
| Prometheus | 10 GiB | monitoring |
| Grafana | 2 GiB | monitoring |
| Alertmanager | 2 GiB | monitoring |
| Vault | 4 GiB | vault |
