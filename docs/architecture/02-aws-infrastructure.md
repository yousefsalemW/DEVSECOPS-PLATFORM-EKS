# Diagram 02 — AWS Infrastructure

Physical layout. Only resources that exist in `terraform/` are shown.

```mermaid
flowchart TB
    IGW["Internet Gateway"]

    subgraph VPC["VPC vprofile-vpc · 10.0.0.0/16"]
        direction TB

        subgraph AZA["eu-west-3a"]
            direction TB
            PUBA["Public 10.0.1.0/24<br/>NAT-a + EIP"]
            PRIA["Private 10.0.11.0/24<br/>node-1 · Jenkins EC2"]
            PUBA -.->|route| PRIA
        end

        subgraph AZB["eu-west-3b"]
            direction TB
            PUBB["Public 10.0.2.0/24<br/>NAT-b + EIP"]
            PRIB["Private 10.0.12.0/24<br/>node-2"]
            PUBB -.->|route| PRIB
        end

        subgraph AZC["eu-west-3c"]
            direction TB
            PUBC["Public 10.0.3.0/24<br/>NAT-c + EIP"]
            PRIC["Private 10.0.13.0/24<br/>node-3"]
            PUBC -.->|route| PRIC
        end

        ALB["ALB — internet-facing<br/>target-type: ip"]
        CP["EKS control plane<br/>private endpoint · KMS-encrypted secrets"]
    end

    ECR["ECR ×5<br/>lifecycle policies"]
    S3V["S3 velero-backups<br/>versioned · AES256 · 35d lifecycle"]
    S3T["S3 terraform-state<br/>native locking"]
    KMS1["KMS — cluster secrets"]
    KMS2["KMS — vault unseal<br/>rotation on · 30d window"]

    IGW --> PUBA & PUBB & PUBC
    IGW --> ALB
    ALB --> PRIA & PRIB & PRIC
    PRIA & PRIB & PRIC --> CP
    PRIA -.-> ECR
    PRIA -.-> S3V
    CP --> KMS1

    classDef pub fill:#e8f5e9,stroke:#43a047,color:#1b5e20
    classDef pri fill:#e3f2fd,stroke:#1976d2,color:#0d47a1
    classDef svc fill:#fff8e1,stroke:#f57c00,color:#e65100
    class PUBA,PUBB,PUBC,ALB,IGW pub
    class PRIA,PRIB,PRIC,CP pri
    class ECR,S3V,S3T,KMS1,KMS2 svc
```

## Resource inventory

| Resource | Count | Source |
|---|---|---|
| VPC | 1 | `vpc.tf` |
| Public subnets | 3 | `10.0.1-3.0/24` |
| Private subnets | 3 | `10.0.11-13.0/24` |
| Internet Gateway | 1 | module |
| NAT Gateways | 3 | `one_nat_gateway_per_az = true` |
| Route tables | 5 | 1 public shared + 3 private + default |
| EKS cluster | 1 | `eks.tf`, v1.34 |
| Managed node group | 1 | 3× `m7i-flex.large`, max 5 |
| Jenkins EC2 | 1 | `m7i-flex.large`, 80 GiB |
| ECR repositories | 5 | `ecr-jenkins.tf` |
| S3 buckets | 2 | Velero + Terraform state |
| KMS keys | 2 | Cluster secrets + Vault unseal |

## Subnet tags — why they matter

```hcl
public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }
private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
```

Without these the AWS Load Balancer Controller cannot select subnets. The Ingress is accepted by
the API server and **no ALB is ever created** — a silent failure with no error anywhere.

## Not present

RDS · ElastiCache · Amazon MQ · Route 53 · ACM · CloudWatch dashboards
