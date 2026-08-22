# VProfile Helm Chart — Reference Guide

A pre-deployment reference. Everything here is written from the **actual files** in `helm/vprofile/` at commit `8e187ce`. No invented files, no invented resources.

---

## 0. Terms you need first

Before anything else, here are the words that will keep coming up.

| Term | What it means |
|---|---|
| **Kubernetes manifest** | A YAML file describing something you want in the cluster (a Pod, a Service, and so on). |
| **Helm** | A tool that takes YAML files **with blanks in them**, fills the blanks with values, and sends the result to Kubernetes. |
| **Chart** | A folder in the layout Helm understands: `Chart.yaml` + `values.yaml` + `templates/`. |
| **Template** | A YAML file containing blanks written as `{{ ... }}`. |
| **Rendering** | The act of filling in those blanks. The output is plain, ordinary YAML. |
| **Release** | An **installed copy** of the chart in the cluster, with a name. Ours is called `vprofile`. |
| **Resource** | The thing that actually exists inside Kubernetes after a manifest is sent. |

**The whole idea in one sentence:** the Chart is a **stencil**; the Release is the **printed copy** made from it.

---

## 1. What this chart actually contains

```
helm/vprofile/
├── Chart.yaml                    ← identity card for the chart
├── values.yaml                   ← default values
└── templates/
    ├── _helpers.tpl              ← shared functions (not a manifest)
    ├── NOTES.txt                 ← post-install message (not a manifest)
    ├── 10-db01.yaml              ← MySQL
    ├── 20-mc01.yaml              ← Memcached
    ├── 30-rmq01.yaml             ← RabbitMQ
    ├── 40-app01.yaml             ← Tomcat
    ├── 50-vproweb.yaml           ← Nginx
    └── 60-ingress.yaml           ← ALB
```

**Ten files. That is all of them.**

### Resources this chart creates

| Kind | Count | Defined in |
|---|---|---|
| Service | 5 | one per component file |
| Deployment | 4 | mc01, rmq01, app01, vproweb |
| StatefulSet | 1 | db01 |
| Ingress | 1 | 60-ingress |
| Secret | 0 or 1 | depends on configuration (see below) |

**Total: 11 or 12 objects.**

### Things you asked about that are NOT in this chart

| | Status |
|---|---|
| **ConfigMap** | ❌ **None at all.** All configuration is either baked into the container images at build time, or comes from a Secret. |
| **NetworkPolicy** | ❌ **None.** And if you added one today it **would not be enforced** — your `vpc-cni` addon still has `enableNetworkPolicy` turned off. That is a Terraform setting, not a chart setting. |
| **PersistentVolumeClaim** | ⚠️ **No file defines one** — but a PVC does get created. Explained in section 3.7. |
| **Chart.lock / charts/** | ❌ This chart has no dependencies, so these files do not exist. |

Do not go looking for files that were never there.

---

## 2. File-by-file

### 2.1 `helm/vprofile/Chart.yaml`

**Purpose.** The identity card of the chart. Its presence is what tells Helm "this folder is a chart."

**Why it exists.** It is mandatory. Without it, Helm refuses the folder entirely.

**What it contains.** `apiVersion: v2` (the Helm 3 format), `name: vprofile`, `version: 1.0.0` (the version of the **chart**), `appVersion: "2.0"` (the version of the **application** — documentation only, it changes no behaviour), a description, and a maintainer name.

**Depends on.** Nothing.

**Depended on by.** `_helpers.tpl` reads `.Chart.Name` and `.Chart.Version` to build a label. `NOTES.txt` reads `.Chart.AppVersion`.

**Relationship to the rest.** It is the entry point. Helm reads it first.

> *General Helm knowledge, not used here:* `Chart.yaml` can also carry a `dependencies:` section listing other charts to pull in — that is the "umbrella chart" pattern. **This chart has no `dependencies:` section.**

---

### 2.2 `helm/vprofile/values.yaml`

**Purpose.** Every value that might change between one deployment and another, gathered in one place.

**Why it exists.** To separate **shape** (which lives in `templates/`) from **values** (which live here). That is what lets you deploy the same chart to dev and prod with different settings without editing a single template.

**What it contains.** Seven groups:

| Group | Controls |
|---|---|
| `image` | registry, tag, pull policy — **deliberately left empty** |
| `db` | database name, and where the password comes from |
| `storage` | StorageClass name and volume size |
| `ingress` | enabled flag, class, scheme, health check path |
| `app` / `web` | replica counts and resource requests/limits |
| `database` / `memcached` / `rabbitmq` | resource requests/limits |

**Depends on.** Nothing.

**Depended on by.** **Every file** in `templates/`.

**A deliberate design choice.** `image.registry` and `image.tag` are empty, and so is the database password. This is not an oversight. If the pipeline forgets to pass them, rendering **fails with a clear message** instead of quietly deploying a broken image or an empty password.

---

### 2.3 `helm/vprofile/templates/_helpers.tpl`

**Purpose.** Shared functions. This file is **not a manifest** — it never produces a Kubernetes object.

**Why the leading underscore?** It is a Helm convention: any file inside `templates/` whose name starts with `_` is treated as a **code fragment**, not as a manifest. Remove the underscore and Helm would try to parse it as YAML and fail.

**What it contains.** Four functions:

| Function | What it does | Used by |
|---|---|---|
| `vprofile.labels` | Emits three consistent labels | all five component files |
| `vprofile.image` | Builds the full image reference, and **fails rendering** if registry or tag is missing | the five components |
| `vprofile.dbSecretName` | Returns the Secret name — either the one you supplied or the one the chart creates | `10-db01`, `40-app01` |
| `vprofile.requireDbSecret` | **Stops rendering** if no password source was given | `10-db01` |

**Depends on.** `values.yaml` (reads `.Values.image.*` and `.Values.db.*`) and `Chart.yaml`.

**Depended on by.** All six manifest files.

**Why it exists.** It removes repetition — the same three labels would otherwise appear in twelve places — and, more importantly, it **guarantees consistency**. The clearest example is `vprofile.dbSecretName`: both `db01` and `app01` call it, so it is impossible for one to point at a different Secret than the other.

---

### 2.4 `helm/vprofile/templates/10-db01.yaml` — MySQL

**Purpose.** The database and its persistent storage.

**What it contains.** Three objects (or two):

| # | Object | Note |
|---|---|---|
| 1 | `Secret` — **conditional** | Created **only** when `db.existingSecret` is empty |
| 2 | `Service` named `db01` | **Headless** (`clusterIP: None`) |
| 3 | `StatefulSet` named `db01` | One replica, plus `volumeClaimTemplates` |

**Main sections inside the StatefulSet.** `envFrom.secretRef` pulls `MYSQL_ROOT_PASSWORD` out of the Secret; a `volumeMount` at `/var/lib/mysql`; readiness and liveness probes that run an **authenticated** `mysqladmin ping`; and `volumeClaimTemplates`, which is what produces the PVC.

**Depends on.** `values.yaml` (`db`, `storage`, `database`), `_helpers.tpl` (three functions), the `vprofile-db` image in ECR, and **a StorageClass named `gp3` existing in the cluster**.

**Depended on by.** `40-app01.yaml`, which waits for `db01:3306` and reads the same Secret.

**Why a StatefulSet and not a Deployment?** A Deployment treats its pods as interchangeable copies. A database is not interchangeable — it owns data on a disk that must survive. A StatefulSet gives the pod a **stable name** (`db01-0`) and a **stable disk** that is reattached every time.

---

### 2.5 `helm/vprofile/templates/20-mc01.yaml` — Memcached

**Purpose.** In-memory cache.

**What it contains.** A `Service` named `mc01` and a `Deployment` with one replica.

**Depends on.** `values.yaml` (`image`, `memcached`), `_helpers.tpl`, the `vprofile-mc` image.

**Depended on by.** `40-app01.yaml` (waits for `mc01:11211`).

**Why a Deployment?** Cache contents are disposable. If the pod dies, the data is simply rebuilt from the database. No storage means no need for a StatefulSet.

---

### 2.6 `helm/vprofile/templates/30-rmq01.yaml` — RabbitMQ

**Purpose.** Message queue.

**What it contains.** A `Service` named `rmq01`, and a `Deployment` with one replica whose readiness probe runs `rabbitmq-diagnostics`.

**Depends on.** `values.yaml` (`image`, `rabbitmq`), `_helpers.tpl`, the `vprofile-rmq` image.

**Depended on by.** `40-app01.yaml`.

**Note.** No credentials are set here. The application connects as `guest/guest`, which is the image's built-in default.

---

### 2.7 `helm/vprofile/templates/40-app01.yaml` — Tomcat

**Purpose.** The application itself. This is the centre of the chart.

**What it contains.** A `Service` named `app01` on port 8080, and a `Deployment` with **two replicas**.

**Three sections worth understanding:**

**`initContainers`.** A small `busybox` container that waits until `db01`, `mc01` and `rmq01` are all accepting connections. Tomcat does not start until it finishes.
> Why: Spring builds its database connection **during application startup**. If MySQL is not ready, the startup fails and **Tomcat then serves 404 for the rest of that pod's life** — it does not crash, so Kubernetes never restarts it. Waiting here is much cheaper than a silent, permanent failure.

**`env.JDBC_PASSWORD`.** Takes the password from the same Secret as `db01`, and overrides the value that was compiled into the application's WAR file at build time.

**Probes on `/login`, not `/`.** Tomcat answers `/` with a redirect (HTTP 302), and a probe with default settings treats a 302 as a failure.

**Depends on.** `values.yaml` (`image`, `app`, `db`), `_helpers.tpl`, the `vprofile-app` image, the three backend Services existing, and the Secret.

**Depended on by.** `50-vproweb.yaml`, which proxies to it.

---

### 2.8 `helm/vprofile/templates/50-vproweb.yaml` — Nginx

**Purpose.** The front-end web tier. It forwards requests to `app01`.

**What it contains.** A `Service` of type **NodePort** named `vproweb`, and a `Deployment` with two replicas.

**Why NodePort rather than LoadBalancer?** If this Service were of type `LoadBalancer`, Kubernetes would create a **second load balancer** alongside the ALB that the Ingress already creates — two bills for one job.

**Depends on.** `values.yaml` (`image`, `web`), `_helpers.tpl`, the `vprofile-web` image, and **a Service named `app01`** (that hostname is hard-coded inside the image's `nginx.conf`).

**Depended on by.** `60-ingress.yaml`.

---

### 2.9 `helm/vprofile/templates/60-ingress.yaml` — ALB

**Purpose.** The public entrance. It tells the AWS Load Balancer Controller to create an ALB pointing at the application.

**What it contains.** A single `Ingress`, wrapped in `{{- if .Values.ingress.enabled }}`.

**Main sections.** Annotations describing the ALB (`scheme`, `target-type: ip`, `healthcheck-path`, `success-codes`), an `ingressClassName: alb`, and one routing rule sending `/` to `vproweb:80`.

**Depends on.** `values.yaml` (`ingress`), `_helpers.tpl`, **the AWS Load Balancer Controller being installed**, and a Service named `vproweb`.

**Depended on by.** Nothing. It is the last link.

**⚠️ This is the only object that costs money directly** (roughly $0.65/day). Setting `ingress.enabled=false` removes it entirely.

---

### 2.10 `helm/vprofile/templates/NOTES.txt`

**Purpose.** The message printed to your terminal after an install or upgrade.

**Not a manifest.** Helm treats this filename as a special case: it renders it, prints it, and **never sends it to the cluster**.

**What it contains.** The deployed image tag, commands for watching the pods, and the command for fetching the ALB address.

**Depends on.** `values.yaml`, `Chart.yaml`, and `.Release.Namespace`.

---

## 3. How everything relates

### 3.1 How `values.yaml` affects the templates

A template says:

```yaml
replicas: {{ .Values.app.replicas }}
```

`.Values` is the entire contents of `values.yaml`, exposed as a tree. `.Values.app.replicas` walks down to `app`, then `replicas`. During rendering, Helm substitutes `2` where the braces were.

**Precedence when the same key is set more than once** — strongest first:

```
1. --set image.tag=abc        ← command line (wins)
2. -f my-values.yaml          ← an extra values file
3. values.yaml                ← the chart default (weakest)
```

So `--set image.tag=abc12345-7` overrides the empty default.

### 3.2 What `_helpers.tpl` does

A template says:

```yaml
labels: {{- include "vprofile.labels" . | nindent 4 }}
```

- `include "vprofile.labels"` — run that function
- `.` — pass it the whole context, so it can reach `.Values` and `.Chart`
- `| nindent 4` — indent the result by four spaces so the surrounding YAML stays valid

**Helm loads every file first and builds an index of function names, then renders.** File location is irrelevant; matching happens purely by name.

### 3.3 How Helm renders templates into manifests

```
1. Read Chart.yaml            → this is a chart named vprofile
2. Read values.yaml           → default values
3. Merge --set and -f on top  → final values
4. Load every file in templates/  → build the function index from _*.tpl
5. Render each file           → fill in every {{ }}
   └─ if a `fail` or a missing `required` triggers → stop here, nothing is sent
6. Output is plain YAML       → exactly what `helm template` shows you
7. Send it to the Kubernetes API server
```

**Step 5 matters.** If rendering fails, **nothing at all is sent**. There is no half-applied deployment — it is all or nothing.

### 3.4 What `helm install` does

```bash
helm install vprofile helm/vprofile -n vprofile
```

1. Renders, as above.
2. Sends the manifests to the API server.
3. Stores a **Release** record named `vprofile` as a Secret inside the namespace — this is Helm's own memory of what it deployed.
4. Prints `NOTES.txt`.

**It fails if a release with that name already exists.**

### 3.5 What `helm upgrade --install` does — and why we use this one

```bash
helm upgrade --install vprofile helm/vprofile -n vprofile --set ...
```

- **If the release does not exist:** behaves exactly like `install`.
- **If it does exist:** renders with the new values, **compares against the previous release**, and sends only the differences.
- The revision number increases (1 → 2 → 3), which is what makes `helm rollback` possible.

**Why we always use it.** It is **safe to repeat**. The same command works the first time, the second time and the tenth time. That is exactly what a pipeline needs — it can call this without first asking "is it already installed?"

### 3.6 How Helm files map to Kubernetes resources

| File | Produces | What Kubernetes then does |
|---|---|---|
| `10-db01.yaml` | Secret + Service + StatefulSet | StatefulSet creates pod `db01-0` and a PVC |
| `20-mc01.yaml` | Service + Deployment | Deployment creates a ReplicaSet, which creates a pod |
| `30-rmq01.yaml` | Service + Deployment | same |
| `40-app01.yaml` | Service + Deployment | Deployment creates **2 pods** |
| `50-vproweb.yaml` | Service + Deployment | Deployment creates **2 pods** |
| `60-ingress.yaml` | Ingress | the Load Balancer Controller reads it and creates a real **ALB in AWS** |

**The key point:** Helm only **sends manifests**. Pods, volumes and load balancers are created by **Kubernetes and its controllers**. Once the manifests are sent, Helm is out of the picture.

### 3.7 Relationships between the resources themselves

**Deployment → Pod**
A Deployment does not create pods directly. It creates a **ReplicaSet**, and the ReplicaSet creates the pods. When you change the image, it creates a new ReplicaSet and shifts pods across gradually.

**StatefulSet → Pod → PVC**

```
StatefulSet db01
  └─ Pod db01-0                      ← stable name, not random
       └─ PVC data-db01-0            ← generated from volumeClaimTemplates
            └─ PersistentVolume      ← created automatically
                 └─ EBS volume in AWS
```

**This answers the PVC question.** There is no PVC file in the chart. The `volumeClaimTemplates` block inside the StatefulSet makes Kubernetes create one PVC **per pod**, named `data-db01-0`. That PVC **survives `helm uninstall`** — deliberately, so you cannot lose the database by accident.

**Service → Pod (matched by labels, not by name)**

```yaml
# in the Service
selector:
  app: db01
# in the Pod
labels:
  app: db01
```

The Service asks for "every pod carrying the label `app: db01`". Pod names and node placement are irrelevant. **If the two do not match, the Service has no endpoints and connections fail with no obvious error message.**

**Pod → Secret** — two forms, both used here:

```yaml
# db01: every key in the Secret becomes an environment variable
envFrom:
  - secretRef: { name: db01-credentials }

# app01: one key, exposed under a different variable name
env:
  - name: JDBC_PASSWORD
    valueFrom:
      secretKeyRef: { name: db01-credentials, key: MYSQL_ROOT_PASSWORD }
```

**Ingress → Service**

```
Ingress → vproweb:80 → pods labelled app: vproweb
```

The Ingress references a Service **by name**. If that Service does not exist, the ALB is created with no healthy targets.

**Pod → ConfigMap** — *general Kubernetes knowledge; **not used in this project**.* A ConfigMap holds non-secret configuration and can be mounted as a file or exposed as environment variables. This chart has none; configuration is baked into the images or supplied by the Secret.

**The full request path:**

```
user → ALB → Ingress → Service vproweb → nginx pods
                                            ↓
                                 Service app01 → tomcat pods
                                            ↓
                         Services db01 / mc01 / rmq01
                                            ↓
                                 pod db01-0 → PVC → EBS
```

---

## 4. Prerequisites before deploying

Everything below must already exist when you run the install.

| Prerequisite | Why it matters | How to check |
|---|---|---|
| Worker nodes running | No nodes means every pod stays `Pending` | `kubectl get nodes` |
| All 5 images in ECR | With the exact tag you pass | `aws ecr describe-images ...` |
| **A StorageClass named `gp3`** | Without it the PVC stays `Pending` forever | `kubectl get sc` |
| **AWS Load Balancer Controller** | Without it the Ingress is accepted and **no ALB is ever created** | `kubectl -n kube-system get deploy` |
| Namespace `vprofile` | Or pass `--create-namespace` | `kubectl get ns` |
| **A Secret containing `MYSQL_ROOT_PASSWORD`** | Without it rendering fails | `kubectl -n vprofile get secret` |
| kubeconfig for the right user | It differs between `ssm-user` and `jenkins` | `kubectl get nodes` |
| **You are on the Jenkins EC2** | The cluster endpoint is private — no access from a laptop | — |

**The first two of these come from `platform/bootstrap-addons.sh`.** That is why the script runs **before** the chart.

### The full deploy command

```bash
kubectl -n vprofile create secret generic db01-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD='<strong password>'

helm upgrade --install vprofile helm/vprofile \
  --namespace vprofile --create-namespace \
  --set image.registry="<account>.dkr.ecr.eu-west-3.amazonaws.com" \
  --set image.tag="<git-sha>-<build-number>" \
  --set db.existingSecret=db01-credentials \
  --timeout 10m
```

---

## 5. Helm commands in this project

### Commands actually used

| Command | What it does |
|---|---|
| `helm lint <chart>` | Quick structural check. **Warning: it passes even on a chart that would deploy nothing** |
| `helm template <name> <chart> --set ...` | **Renders and prints, sending nothing to the cluster.** The most useful command for reviewing before you deploy |
| `helm upgrade --install <name> <chart> -n <ns> --set ...` | Installs or updates. Safe to repeat |
| `helm uninstall <name> -n <ns>` | Removes all resources **including the ALB**. The PVC **survives** |
| `helm repo add eks https://aws.github.io/eks-charts` | Adds an external chart repository — used in `bootstrap-addons.sh` |
| `helm upgrade --install aws-load-balancer-controller eks/... --wait` | Installs the Load Balancer Controller — also in `bootstrap-addons.sh` |

### Commands useful when something breaks

| Command | What it does |
|---|---|
| `helm list -n vprofile` | What is deployed and at which revision |
| `helm status vprofile -n vprofile` | Release state plus the NOTES message |
| `helm get manifest vprofile -n vprofile` | The YAML that was **actually** sent — compare it against what you expected |
| `helm get values vprofile -n vprofile` | The values that were actually used |
| `helm history vprofile -n vprofile` | Every previous revision |
| `helm rollback vprofile <revision> -n vprofile` | Return to an earlier revision |
| `helm diff upgrade ...` | Shows the change before applying it — *requires a plugin that is **not installed** on your Jenkins box* |

### Flags that matter

| Flag | Effect |
|---|---|
| `--set key=value` | Override a single value; highest precedence |
| `-n <ns> --create-namespace` | Target namespace, creating it if absent |
| `--timeout 10m` | Maximum time to wait |
| `--wait` | Do not return until everything is Ready — used for the Load Balancer Controller |
| `--atomic` | Roll back automatically on failure. **Do not use on a first deploy** — it deletes the very pods you need to inspect |
| `--dry-run` | Render and validate against the API without creating anything |

---

## 6. Architecture map

```
                      helm/vprofile/
                            │
      ┌─────────────────────┼─────────────────────┐
      │                     │                     │
  Chart.yaml           values.yaml          templates/
  (identity)            (values)             (shape)
      │                     │                     │
      └──────────┬──────────┘                     │
                 │                                │
                 └────────────┬───────────────────┘
                              ↓
                      ┌───────────────┐
                      │ HELM RENDERING│  ← _helpers.tpl runs here
                      │  {{ }} → values│ ← --set overrides values.yaml
                      └───────┬───────┘  ← required / fail stop here
                              ↓
                   Kubernetes Manifests (plain YAML)
                              ↓
                    Kubernetes API Server
                              ↓
      ┌──────────┬──────────┬─────────┬──────────┐
   Secret     Services   Deployments StatefulSet Ingress
    (1)         (5)          (4)         (1)       (1)
      │          │           │           │          │
      │          │           ↓           ↓          ↓
      │          │      ReplicaSets    Pod         ALB
      │          │           ↓        db01-0     (in AWS)
      │          │         Pods          ↓          │
      │          │      (2 app01,       PVC         │
      │          │       2 vproweb,      ↓          │
      │          │       1 mc01,         PV         │
      │          │       1 rmq01)        ↓          │
      │          │                  EBS volume      │
      │          └── routes to pods ──┘             │
      └── injects the password into db01-0 & app01 ─┘
                                                     │
   user ─────────────────────────────────────────────┘
        ↓
   ALB → vproweb (nginx) → app01 (tomcat) → db01 / mc01 / rmq01
        ↓
   Running VProfile application
```

### Startup order

```
1. db01-0 starts       → PVC binds → MySQL initialises → Ready
2. mc01 / rmq01        → Ready
3. app01 initContainer waits for all three → exits
4. app01 tomcat starts → Spring connects to the DB → /login = 200 → Ready
5. vproweb starts      → nginx resolves app01 → Ready
6. Controller sees the Ingress → creates the ALB (2-3 minutes)
7. ALB health check hits /login = 200 → targets healthy
8. The site is live
```

---

## 7. Quick reference

| File | Produces | Depends on | Depended on by |
|---|---|---|---|
| `Chart.yaml` | identity | — | `_helpers`, `NOTES` |
| `values.yaml` | values | — | **every template** |
| `_helpers.tpl` | 4 functions | values, Chart | all six manifests |
| `10-db01.yaml` | Secret? + Svc + StatefulSet | values, helpers, `gp3` SC | `40-app01` |
| `20-mc01.yaml` | Svc + Deployment | values, helpers | `40-app01` |
| `30-rmq01.yaml` | Svc + Deployment | values, helpers | `40-app01` |
| `40-app01.yaml` | Svc + Deployment | values, helpers, db01/mc01/rmq01, Secret | `50-vproweb` |
| `50-vproweb.yaml` | Svc + Deployment | values, helpers, `app01` | `60-ingress` |
| `60-ingress.yaml` | Ingress | values, helpers, `vproweb`, LB Controller | — |
| `NOTES.txt` | message | values, Chart | — |

---

## 8. Three mistakes that cost the most time

**1. Service names cannot be changed.** `db01`, `mc01`, `rmq01` and `app01` are compiled into the images at build time. If you rename a Service, Helm succeeds, the pods run — **and the application breaks with no clear error**.

**2. An Ingress without its controller fails silently.** The Ingress is accepted, stored, and shown by `kubectl get ingress` — and **no ALB is ever created**. No error, no event. That is why `bootstrap-addons.sh` checks that the controller's CRD exists.

**3. `helm lint` passes on a chart that deploys nothing.** If the template files are not inside a folder named `templates/`, lint reports success and install reports success, but **nothing is created**. The real check is counting objects:

```bash
helm template x helm/vprofile --set image.registry=r --set image.tag=t \
  --set db.existingSecret=s | grep -c '^kind:'
# must print 11
```

---

*Written from the actual files in `helm/vprofile/` at commit `8e187ce`.*
