# Diagram 06 — Security & Secrets

Identity and secret flow. Every arrow is an implemented control.

```mermaid
flowchart TB
    subgraph IAM["AWS IAM"]
        direction TB
        EC2R["jenkins-ec2-role<br/>SSM · ECR · eks:Describe<br/>sts:AssumeRole → 1 ARN"]
        PLATR["jenkins-platform-role<br/>trusted ONLY by jenkins-ec2-role<br/>max_session_duration 3600"]
        EC2R ==>|sts:AssumeRole<br/>CloudTrail: jenkins-platform-BUILD| PLATR
    end

    subgraph IRSA["IRSA — 4 roles, no static keys"]
        direction TB
        R1["vprofile-lb-controller<br/>← kube-system:aws-load-balancer-controller"]
        R2["vprofile-ebs-csi<br/>← kube-system:ebs-csi-controller-sa"]
        R3["vprofile-velero<br/>← velero:velero-server"]
        R4["vprofile-vault<br/>← vault:vault<br/>KMS Encrypt/Decrypt — ONE key"]
    end

    OIDC["EKS OIDC provider"]
    OIDC --> R1 & R2 & R3 & R4

    subgraph EKSACC["EKS Access Entries"]
        E1["jenkins-ec2-role<br/>EKSEditPolicy<br/>scope: namespace vprofile"]
        E2["jenkins-platform-role<br/>EKSClusterAdmin<br/>scope: cluster"]
    end
    EC2R --> E1
    PLATR --> E2

    subgraph VAULTB["Vault — namespace: vault"]
        direction TB
        VSA["SA: vault → IRSA vprofile-vault"]
        VSEAL["seal awskms → KMS auto-unseal"]
        VPOL["policy vprofile-app<br/>path vprofile/data/app01<br/>capabilities [read]<br/>NO list"]
        VROLE["k8s auth role vprofile-app<br/>bound SA: app01<br/>bound ns: vprofile<br/>TTL 3600 · alias by UID"]
    end

    subgraph APPNS["namespace: vprofile"]
        SA1["SA app01 — token mounted"]
        SA2["SA db01/mc01/rmq01/vproweb<br/>automountServiceAccountToken: false"]
        K8SEC["Secrets db01-credentials<br/>rmq01-credentials<br/>KMS-encrypted at rest"]
        POD["app01 pod<br/>⚠ reads K8s Secrets, NOT Vault"]
    end

    SA1 -->|SA token| VROLE
    VROLE --> VPOL
    K8SEC --> POD
    VPOL -.->|❌ not wired| POD

    classDef iam fill:#fce4ec,stroke:#c2185b,color:#880e4f
    classDef vault fill:#f3e5f5,stroke:#8e24aa,color:#4a148c
    classDef app fill:#e3f2fd,stroke:#1976d2,color:#0d47a1
    classDef gap fill:#ffebee,stroke:#e53935,color:#b71c1c
    class EC2R,PLATR,R1,R2,R3,R4,E1,E2,OIDC iam
    class VSA,VSEAL,VPOL,VROLE vault
    class SA1,SA2,K8SEC app
    class POD gap
```

## The AssumeRole boundary

| | Detail |
|---|---|
| **Prevents** | The application pipeline cannot touch `kube-system`, `vault`, `monitoring` or `velero` — even if `Jenkinsfile` is edited — because its role lacks the access |
| **Provides** | Attribution. CloudTrail records `AssumeRole` with session name `jenkins-platform-<build>` |
| **Does NOT prevent** | Anyone who can commit to `Jenkinsfile-platform` can assume the role. **Branch protection is not configured** — that is the control which closes this gap |

## Why ClusterAdmin, and why that is still least privilege

`AmazonEKSAdminPolicy` maps to the Kubernetes `admin` ClusterRole, which is **namespace-scoped**
and excludes CustomResourceDefinitions, ClusterRoles and webhook configurations — all three of
which the add-on charts create.

**The isolation is the separate assumed role, not a reduced policy.** The power exists only inside
a one-hour session, never as a standing grant.

## The Vault identity chain

```
Pod runs as ServiceAccount app01 (namespace vprofile)
      ↓ presents projected SA token
Vault validates via Kubernetes TokenReview API
      ↓ matches bound_service_account_names + bound_service_account_namespaces
Role vprofile-app → policy vprofile-app
      ↓
read on vprofile/data/app01 — 1-hour TTL
```

**Verified:** a login with the `app01` token returned `token_policies ["default" "vprofile-app"]`
and `token_meta_service_account_namespace: vprofile`.

**Alias by `serviceaccount_uid`, not name** — delete and recreate `app01` and it gets a new UID,
so a stale token cannot be replayed.

## ⚠️ The integration gap

The application reads its credentials from **Kubernetes Secrets**, not Vault. No
`vault.hashicorp.com/*` annotations exist in any chart template.

To close it:
1. Vault Agent Injector annotations on the `app01` pod template
2. A NetworkPolicy egress rule for `vprofile → vault` — currently **denied** by `default-deny`
3. Accept that Spring resolves placeholders at startup, so rotation needs a pod restart regardless

## Defence in depth summary

```
AWS IAM         2 Jenkins roles (one assumable) + 4 IRSA roles, no static keys
Network         private subnets · private cluster endpoint · SSM not SSH
K8s RBAC        access entries, CI scoped to one namespace
Pod network     6 NetworkPolicies, default-deny, CNI enforcement ON
Workload        drop ALL · no privilege escalation · seccomp RuntimeDefault
Secrets         KMS-encrypted at rest · none in Git · chart fails without them
Supply chain    Trivy pre-push · CycloneDX SBOM · commit-SHA tags
```
