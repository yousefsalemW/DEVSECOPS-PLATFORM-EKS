# Diagram 05 — Monitoring & Observability

Metric flow, exactly as deployed. The gaps are drawn as well as the paths.

```mermaid
flowchart LR
    subgraph SOURCES["Metric sources"]
        direction TB
        KSM["kube-state-metrics<br/>object state"]
        NE["node-exporter<br/>DaemonSet ×3"]
        KUBELET["kubelet / cAdvisor<br/>container metrics"]
        API["kube-apiserver"]
        CORE["CoreDNS"]
    end

    PROM["Prometheus<br/>retention 7d<br/>retentionSize 8GiB<br/>10 GiB gp3"]

    KSM & NE & KUBELET & API & CORE -->|scrape| PROM

    PROM --> GRAF["Grafana<br/>24 dashboards<br/>2 GiB · no Ingress"]
    PROM --> RULES["PrometheusRules<br/>alert evaluation"]
    RULES --> AM["Alertmanager<br/>120h retention"]
    AM -.->|❌ NO RECEIVERS| NOWHERE["(alerts go nowhere)"]

    SM["ServiceMonitor CRDs<br/>selectorNilUsesHelmValues: false<br/>→ discovers ALL namespaces"] -.->|configures| PROM

    OFF1["❌ kubeEtcd"]
    OFF2["❌ kubeControllerManager"]
    OFF3["❌ kubeScheduler"]
    OFF4["❌ kubeProxy"]
    OFF1 & OFF2 & OFF3 & OFF4 -.->|AWS-managed<br/>unreachable on EKS| PROM

    MISS1["❌ Log aggregation"]
    MISS2["❌ Tracing"]
    MISS3["❌ Application metrics"]

    classDef src fill:#e8f5e9,stroke:#43a047,color:#1b5e20
    classDef core fill:#e3f2fd,stroke:#1976d2,color:#0d47a1
    classDef gap fill:#ffebee,stroke:#e53935,color:#b71c1c
    class KSM,NE,KUBELET,API,CORE src
    class PROM,GRAF,RULES,AM,SM core
    class OFF1,OFF2,OFF3,OFF4,MISS1,MISS2,MISS3,NOWHERE gap
```

## Monitoring vs. observability

**Monitoring** answers questions you knew to ask. **Observability** is the ability to answer
questions you did not anticipate — normally requiring metrics, logs *and* traces correlated per
request.

This project has **metrics only**. Calling it observability would overstate it; it is solid
infrastructure monitoring.

## The EKS-specific correction

On EKS the control plane is AWS-managed and unscrapeable. At their chart defaults, four scrape
targets produce **four permanently-firing alerts and empty panels from the first minute**.

**Disabling the scrape target is only half the fix.** The alert rule groups are still created and
fire on absent metrics:

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

Verified: zero PrometheusRule groups for the disabled components in the rendered output.

## Cross-namespace discovery

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
```

Without this, Prometheus discovers only ServiceMonitors created by its own Helm release. With it,
a ServiceMonitor placed in the `vprofile` namespace is picked up automatically.

## Measured footprint

```
375m CPU  ·  1.4 GiB RAM requests  ·  14 GiB EBS  ≈  $1.30/month
```

## Gaps

| Gap | Consequence |
|---|---|
| **Alertmanager has no receivers** | Alerts fire and are delivered nowhere. This is monitoring, not alerting. |
| **No log aggregation** | No Loki, no Fluent Bit. Debugging means `kubectl logs` per pod. |
| **No application metrics** | The Java app exposes no JVM or business metrics. No request rate, error rate or latency. |
| **No tracing** | Cannot follow a request across the five tiers. |
