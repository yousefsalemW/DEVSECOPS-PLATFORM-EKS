# Diagram 01 — High-Level Architecture

The whole system in one view. Every component shown is deployed.

```mermaid
flowchart LR
    DEV["👤 Developer"] -->|git push| GH["GitHub<br/>DEVSECOPS-PLATFORM-EKS"]
    GH -->|webhook| JEN

    subgraph AWS["AWS · eu-west-3"]
        direction TB
        subgraph CI["CI/CD — private subnet"]
            JEN["Jenkins<br/>EC2 m7i-flex.large"]
            SQ["SonarQube 26.8.0<br/>127.0.0.1:9000"]
            JEN <--> SQ
        end

        ECR["Amazon ECR<br/>5 repositories"]

        subgraph EKS["EKS vprofile-eks · 1.34 · private endpoint"]
            direction TB
            APP["namespace: vprofile<br/>nginx → tomcat → mysql<br/>+ memcached + rabbitmq"]
            PLAT["monitoring · velero · vault<br/>kube-system"]
        end

        ALB["Application<br/>Load Balancer"]
        S3["S3<br/>velero backups<br/>terraform state"]
        KMS["KMS<br/>cluster secrets<br/>vault unseal"]
    end

    JEN -->|docker push| ECR
    JEN -->|helm upgrade --install| APP
    ECR -->|image pull| APP
    ALB --> APP
    PLAT -->|IRSA| S3
    PLAT -->|IRSA| KMS
    USER["🌐 End user"] -->|HTTP| ALB

    classDef ext fill:#e8eaf6,stroke:#3949ab,color:#1a237e
    classDef aws fill:#fff8e1,stroke:#f57c00,color:#e65100
    classDef k8s fill:#e3f2fd,stroke:#1976d2,color:#0d47a1
    class DEV,GH,USER ext
    class ECR,ALB,S3,KMS,JEN,SQ aws
    class APP,PLAT k8s
```

## Flow

| Step | Action |
|---|---|
| 1 | Developer pushes to GitHub |
| 2 | Webhook triggers the Jenkins application pipeline |
| 3 | Maven build → SonarQube analysis → Trivy scan + SBOM |
| 4 | Five images pushed to ECR, tagged `<git-sha>-<build>` |
| 5 | `helm upgrade --install --atomic` deploys to the `vprofile` namespace |
| 6 | ALB Controller provisions/updates the ALB from the Ingress |
| 7 | End users reach the application over HTTP through the ALB |

## Boundaries

- **Jenkins and the EKS nodes are in private subnets.** No public IPs. Jenkins is reached via SSM Session Manager.
- **The EKS API endpoint is private-only.** All `kubectl`/`helm` operations originate inside the VPC.
- **The ALB is the only internet-facing component.**
