# VProfile CI/CD Pipeline — Complete Guide

**Source:** `Jenkinsfile` (423 lines) — DEVSECOPS-PLATFORM-EKS
**Purpose:** a standalone reference. After reading this you should be able to reason about the entire pipeline without opening the Jenkinsfile.

> **Source-fidelity rule used throughout.** Everything described here exists in the uploaded Jenkinsfile. Where I add general CI/CD knowledge for context, it is marked **[General knowledge]**. Where something is absent, I say so explicitly rather than describing what "should" be there.

---

# 1. CI/CD Overview

## What this pipeline actually is

This is a **CI pipeline with a security and quality focus**. It takes source code from Git and produces five scanned, signed-with-metadata, immutably-tagged container images in AWS ECR.

**It does not deploy anything.** Searching the Jenkinsfile for `helm` returns 0 matches. Searching for `kubectl` returns 0 matches.

> **This is not implemented in the current Jenkinsfile:** there is no Deploy stage, no Helm invocation, no Kubernetes interaction, and no rollback logic. Deployment is a separate manual step performed on the Jenkins host. Section 22 explains the boundary in detail.

## The complete flow

```
Git Repository (GitHub, public)
        │
        │  Jenkins job configured as "Pipeline from SCM"
        ↓
Jenkins Controller (agent any — builds run on the controller itself)
        │
        ↓
CHECKOUT ─── implicit, performed by Jenkins before stage 1
        │    puts the repo in ${WORKSPACE}
        ↓
Stage 1 · INIT
        │    • GIT_SHA      ← git rev-parse --short=8 HEAD
        │    • BUILD_DATE   ← date -u
        │    • TAG          ← <GIT_SHA>-<BUILD_NUMBER>
        │    • AWS_ACCOUNT_ID ← aws sts get-caller-identity
        │    • ECR_REGISTRY   ← built from account + region
        │    • Trivy vulnerability DB + Java DB downloaded ONCE
        ↓
Stage 2 · MAVEN VERIFY            [conditional: RUN_SONAR]
        │    Runs in maven:3.9.9-eclipse-temurin-11 container
        │    Produces target/classes, target/test-classes,
        │             target/surefire-reports, target/site/jacoco/jacoco.xml
        │    JUnit results published to Jenkins
        ↓
Stage 3 · SONARQUBE               [conditional: RUN_SONAR]
        │    3a. sonarScan()         — analysis uploaded to SonarQube
        │    3b. sonarQualityGate()  — polls the API for the verdict
        │        enforced if SONAR_GATE=true, advisory if false
        ↓
Stage 4 · BUILD
        │    5 images built with BuildKit, --pull, and OCI labels
        ↓
Stage 5 · TRIVY SCAN
        │    per image:  (a) HIGH/CRITICAL report → artifact
        │                (b) CycloneDX SBOM       → artifact
        │                (c) gate                 [conditional: SECURITY_GATE]
        ↓
Stage 6 · ECR LOGIN
        │    Credentials from the EC2 instance profile — none stored in Jenkins
        ↓
Stage 7 · TAG
        │    local name → ECR-qualified name
        ↓
Stage 8 · PUSH
        │    docker push, wrapped in retry(3)
        ↓
Stage 9 · VERIFY
        │    aws ecr describe-images → prints each image digest
        ↓
POST · ALWAYS · CLEANUP
             Runs even on failure. Removes local images, prunes,
             logs out of the registry.
```

## Which stages are mandatory and which are conditional

| Stage | Condition | Controlled by |
|---|---|---|
| Init | **Always** | — |
| Maven Verify | Conditional | `when { expression { params.RUN_SONAR } }` |
| SonarQube | Conditional | `when { expression { params.RUN_SONAR } }` |
| Build | **Always** | — |
| Trivy Scan | **Always** (the scan runs; only the *gate* is conditional) | — |
| ECR Login | **Always** | — |
| Tag | **Always** | — |
| Push | **Always** | — |
| Verify | **Always** | — |
| Cleanup | **Always, including on failure** | `post { always { } }` |

**An important consequence:** setting `RUN_SONAR=false` skips both Maven Verify and SonarQube. The images are still built and pushed — but they are built by the Dockerfile's own internal Maven stage, so the application still compiles. What is lost is the *analysis*, not the build.

---

# 2. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│  Jenkins EC2 (private subnet, no inbound SG, SSM access only)        │
│                                                                       │
│  ┌────────────┐   ┌──────────────┐   ┌───────────────────────────┐  │
│  │  Jenkins   │   │  SonarQube   │   │  Docker daemon            │  │
│  │  :8080     │──▶│  container   │   │                           │  │
│  │            │   │  :9000       │   │  transient containers:    │  │
│  │  workspace │   │  (localhost) │   │   · maven:3.9.9-jdk11     │  │
│  └─────┬──────┘   └──────────────┘   │   · sonar-scanner-cli     │  │
│        │                              │  built images: 5          │  │
│        │  trivy · jq · git · aws cli  └───────────────────────────┘  │
│        │                                                              │
│        │  IAM: EC2 instance profile → jenkins-ec2-role               │
└────────┼──────────────────────────────────────────────────────────────┘
         │
         │ NAT Gateway (egress only)
         ↓
   ┌─────────────┬──────────────┬────────────────┐
   │  GitHub     │   AWS STS    │    AWS ECR     │
   │  (source)   │  (identity)  │  (5 repos,     │
   │             │              │   IMMUTABLE)   │
   └─────────────┴──────────────┴────────────────┘
```

**Key architectural facts visible in the source:**

- `agent any` with no configured agents means **every step runs on the Jenkins controller**. There is no distributed build.
- SonarQube is reached at `http://localhost:9000` (the `SONAR_HOST_URL` default), and the scanner container uses `--network host` to reach it. Both facts confirm SonarQube runs on the same machine.
- Maven and the Sonar scanner run as **throwaway containers**, not as tools installed on the host.
- The only long-lived state on the host is the two cache directories under `/var/lib/jenkins/`.

---

# 3. Jenkinsfile Structure

The file has two distinct halves.

## Half 1 — Top-level Groovy (lines 17–237)

Everything before the `pipeline { }` block is plain Groovy executed when the pipeline script is loaded:

| Element | Lines | What it is |
|---|---|---|
| `IMAGES` | 18–24 | A `List` of `Map`s describing the five images |
| `forEachImage` | 31–37 | Iteration strategy — sequential or parallel |
| `mavenVerify` | 46–59 | Compile and test in a container |
| `sonarScan` | 81–107 | Run the SonarQube scanner |
| `sonarQualityGate` | 112–148 | Poll the SonarQube API for the verdict |
| `buildImage` | 150–173 | `docker build` one image |
| `scanImage` | 175–210 | Trivy report + SBOM + optional gate |
| `tagImage` | 212–217 | Retag for ECR |
| `pushImage` | 219–225 | `docker push` with retry |
| `verifyImage` | 227–237 | Confirm the image landed, print the digest |

## Half 2 — The declarative pipeline (lines 241–423)

```groovy
pipeline {
    agent any          // where steps run
    options { }        // build-level behaviour
    parameters { }     // inputs the user can change per run
    environment { }    // variables available to all stages
    stages { }         // the ordered work
    post { }           // what runs after, regardless of outcome
}
```

## Why helper functions instead of inline steps

This is a deliberate design decision and it is worth understanding, because it is what makes the `stages` block readable:

```groovy
stage('Build') {
    steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> buildImage(img) } } }
}
```

That is the entire Build stage — one line. The 20 lines of `docker build` flags live in `buildImage()`.

**Four concrete benefits:**

1. **The stage list becomes the architecture.** Someone opening the file sees nine stages and understands the flow in ten seconds.
2. **Iteration strategy is decided in one place.** `forEachImage` is called by Build, Trivy Scan and Push. Changing sequential-vs-parallel behaviour is one function, not three copies.
3. **No duplication across five images.** Without helpers, the `docker build` command would appear five times, and a flag added to one would eventually be forgotten in another.
4. **The comments have somewhere to live.** Roughly 40% of the helper section is explanatory comments — the BuildKit caveat, the `SONAR_USER_HOME` permission problem, the OOM warning. Inside a `steps` block those would drown the structure.

**[General knowledge]** Declarative Pipeline restricts what can go directly inside `steps`. Arbitrary Groovy — loops, conditionals, variable assignment — requires a `script { }` block. That is why every stage that calls a helper wraps it in `script { }`.

---

# 4. The IMAGES Map

## Structure

```groovy
def IMAGES = [
    [name: 'vprofile-app', file: 'Build-Images/images/app/Dockerfile',       ctx: 'Build-Images'],
    [name: 'vprofile-db',  file: 'Build-Images/images/db/Dockerfile',        ctx: 'Build-Images'],
    [name: 'vprofile-mc',  file: 'Build-Images/images/memcached/Dockerfile', ctx: 'Build-Images/images/memcached'],
    [name: 'vprofile-rmq', file: 'Build-Images/images/rabbitmq/Dockerfile',  ctx: 'Build-Images/images/rabbitmq'],
    [name: 'vprofile-web', file: 'docker/web/Dockerfile',                     ctx: 'docker/web'],
]
```

Each entry has exactly three fields. Understanding what each one means is essential.

### `name` — the identity that flows through everything

This single string is used in **six** distinct places:

1. Local Docker tag during build → `vprofile-app:abc12345-7`
2. Trivy report filename → `trivy-vprofile-app.txt`
3. SBOM filename → `sbom-vprofile-app.cdx.json`
4. ECR-qualified tag → `<account>.dkr.ecr.<region>.amazonaws.com/vprofile-app:abc12345-7`
5. ECR repository name in `aws ecr describe-images --repository-name vprofile-app`
6. Cleanup — `docker rmi`

**The critical constraint:** `name` must exactly equal the ECR repository name created by Terraform. The pipeline never creates repositories; it assumes they exist. A mismatch surfaces only at the Push stage, as `RepositoryNotFoundException`.

### `file` — which Dockerfile to use

Passed to `docker build -f`. It is a path **relative to the Jenkins workspace root**, not relative to the build context. This is why `vprofile-app` can have its Dockerfile at `Build-Images/images/app/Dockerfile` while its context is `Build-Images`.

### `ctx` — the build context

**[General knowledge]** The build context is the directory tree Docker packages up and sends to the daemon before building. Anything a `COPY` instruction references must be inside it. Anything inside it that is not excluded by `.dockerignore` is transferred whether it is needed or not.

**This is why the contexts differ per image**, and the difference is meaningful:

- `vprofile-app` needs `pom.xml` and `src/` → context must be `Build-Images`
- `vprofile-db` needs `src/main/resources/db_backup.sql` → context must also be `Build-Images`
- `vprofile-mc` and `vprofile-rmq` copy nothing → their contexts are narrowed to their own directories, so almost nothing is transferred
- `vprofile-web` needs `nginx.conf`, which sits beside its Dockerfile → context is `docker/web`

Narrowing the context is both a **performance** decision (less data to transfer) and a **security** decision (a Dockerfile cannot accidentally `COPY` a file it should not have access to).

## Complete image map

| Image | Represents | Dockerfile | Context | Why that context | ECR destination |
|---|---|---|---|---|---|
| `vprofile-app` | Tomcat 9 serving the VProfile Java WAR. Multi-stage: Maven 3.9.9 / JDK 11 builds, `tomcat:9.0-jre11-temurin-jammy` runs | `Build-Images/images/app/Dockerfile` | `Build-Images` | Needs `pom.xml` + `src/` for the Maven stage | `<acct>.dkr.ecr.eu-west-3.amazonaws.com/vprofile-app` |
| `vprofile-db` | MySQL 8.0.43 with the schema seeded from `db_backup.sql` | `Build-Images/images/db/Dockerfile` | `Build-Images` | Needs `src/main/resources/db_backup.sql` | `.../vprofile-db` |
| `vprofile-mc` | Memcached 1.6.38 (alpine), patched | `Build-Images/images/memcached/Dockerfile` | `Build-Images/images/memcached` | Copies nothing — minimal context | `.../vprofile-mc` |
| `vprofile-rmq` | RabbitMQ 3.13 management (alpine), patched | `Build-Images/images/rabbitmq/Dockerfile` | `Build-Images/images/rabbitmq` | Copies nothing | `.../vprofile-rmq` |
| `vprofile-web` | Nginx 1.27 (alpine) reverse-proxying to `app01:8080` | `docker/web/Dockerfile` | `docker/web` | Needs `nginx.conf` from the same directory | `.../vprofile-web` |

## How these names reach Helm

**Not automatically.** The Jenkinsfile does not invoke Helm.

The connection is by **convention**: the Helm chart's `vprofile.image` helper builds image references as `<registry>/<name>:<tag>`, using the same five names. When someone runs `helm upgrade --install ... --set image.registry=X --set image.tag=Y`, the chart reconstructs exactly the references this pipeline pushed. Section 23 covers this in full.

---

# 5. Helper Functions

## 5.1 `forEachImage(List images, boolean parallelMode, Closure body)`

```groovy
def forEachImage(List images, boolean parallelMode, Closure body) {
    if (parallelMode) {
        parallel images.collectEntries { img -> ["${img.name}", { body(img) }] }
    } else {
        images.each { body(it) }
    }
}
```

**A. Purpose.** Decide *how* to iterate over the five images — one at a time, or all at once — in a single place.

**B. Inputs.** The image list; a boolean from `params.PARALLEL`; and a **closure** — a block of code passed as an argument. **[General knowledge]** A closure in Groovy is a function you can hand to another function, which is what makes `forEachImage(IMAGES, false) { img -> buildImage(img) }` read naturally.

**C. Important variables.** `params.PARALLEL`, default `false`.

**D. Commands.** No shell. `collectEntries` converts the list into a `Map` of `name → closure`, which is the shape Jenkins' built-in `parallel` step requires.

**E. Output.** Executes `body` once per image.

**F. Why it exists.** Three stages — Build, Trivy Scan, Push — need the same iteration. Without this helper, switching to parallel would mean editing three places identically.

**G. Failure behaviour.** Sequential: the first failure stops the loop; later images are never processed. Parallel: Jenkins' default `failFast` is off, so other branches continue, and the stage fails at the end.

**H. Relationships.** Called by Build, Trivy Scan and Push. **Notably *not* used by Tag or Verify**, which call `IMAGES.each` directly and are therefore always sequential — those operations are fast and I/O-light, so parallelism would add nothing.

---

## 5.2 `mavenVerify()`

```groovy
def mavenVerify() {
    sh """
        mkdir -p ${env.MAVEN_CACHE}
        docker run --rm \
          -u \$(id -u):\$(id -g) \
          -v "${env.WORKSPACE}/Build-Images":/src -w /src \
          -v ${env.MAVEN_CACHE}:/var/maven/.m2 \
          -e HOME=/var/maven \
          -e MAVEN_CONFIG=/var/maven/.m2 \
          -e MAVEN_OPTS="-Xmx1g" \
          maven:3.9.9-eclipse-temurin-11 \
          mvn -B -Duser.home=/var/maven ${params.SKIP_TESTS ? '-DskipTests' : ''} verify
    """
}
```

**A. Purpose.** Compile and test the Java application *in the Jenkins workspace*, so that compiled bytecode and coverage reports exist for SonarQube to analyse.

**B. Inputs.** None directly. Reads `env.MAVEN_CACHE`, `env.WORKSPACE`, `params.SKIP_TESTS`.

**C. Important variables.**
- `env.MAVEN_CACHE` = `/var/lib/jenkins/.m2` — hardcoded in the `environment` block
- `env.WORKSPACE` — supplied by Jenkins, the job's checkout directory
- `params.SKIP_TESTS` — default `false`

**D. Commands, flag by flag.**

| Flag | What it does | Why it is there |
|---|---|---|
| `--rm` | Delete the container when it exits | The container is a tool invocation, not a service |
| `-u $(id -u):$(id -g)` | Run as the calling user (jenkins), not root | See the deep dive in Section 10 — this is the most important flag here |
| `-v "${WORKSPACE}/Build-Images":/src` | Mount the source into the container | The container has no source of its own; output must land back in the workspace |
| `-w /src` | Set the working directory | So `mvn` finds `pom.xml` |
| `-v ${MAVEN_CACHE}:/var/maven/.m2` | Mount a persistent dependency cache | Without it, every build re-downloads the full dependency tree |
| `-e HOME=/var/maven` | Override the home directory | Required once we are not root — see Section 10 |
| `-e MAVEN_CONFIG=/var/maven/.m2` | Tell Maven where its config lives | Same reason |
| `-e MAVEN_OPTS="-Xmx1g"` | Cap the Maven JVM heap | SonarQube shares this machine's 8 GB |
| `-Duser.home=/var/maven` | Tell the **JVM** the home directory | `HOME` alone is not enough — Java reads `user.home` |
| `-B` | Batch mode | Non-interactive, no ANSI colour codes cluttering the log |
| `verify` | The Maven lifecycle phase | See below |

**E. Output.** Inside `Build-Images/` in the workspace:
- `target/classes/` — compiled application bytecode
- `target/test-classes/` — compiled test bytecode
- `target/surefire-reports/*.xml` — JUnit results
- `target/site/jacoco/jacoco.xml` — coverage report
- `target/*.war` — the packaged application

**F. Why it exists.** This is the pivotal design point of the whole pipeline. The application's Dockerfile is **multi-stage**: it runs Maven *inside* the image build, so the compiled classes exist only in a discarded intermediate layer. The Jenkins workspace never sees them. But SonarQube's Java analyser **requires compiled bytecode** — it does not analyse source alone. So the pipeline compiles a second time, on the host, purely to feed the analyser.

Yes, this means the code is compiled twice per build. That is the accepted cost of keeping the Dockerfile self-contained (it can still be built standalone with `docker build`) while still getting real static analysis.

**G. Failure behaviour.** A non-zero exit fails the stage. With `RUN_SONAR=true` and a compilation error or a failing test, the pipeline stops here — nothing is built or pushed. The `post { always { junit ... } }` block still publishes whatever test results exist, so you can see *which* test failed.

**H. Relationships.** Runs before `sonarScan()`, which depends entirely on its output. If `mavenVerify` is skipped (`RUN_SONAR=false`), `sonarScan` is skipped too — they share the same `when` condition, which is correct, because running the scanner without `target/classes` would produce a meaningless analysis.

---

## 5.3 `sonarScan()`

**A. Purpose.** Send the source, the compiled bytecode, the test results and the coverage data to the SonarQube server for analysis.

**B. Inputs.** None directly; reads `env.SONAR_CACHE`, `env.WORKSPACE`, `env.SONAR_HOST_URL`, `env.TAG`, `env.GIT_SHA`, `params.SONAR_PROJECT_KEY`.

**C. Important variables.** `SONAR_TOKEN` is injected by `withCredentials` from the Jenkins credential with ID `sonar-token`. It exists only inside that block.

**D. Commands.** Detailed in Section 11.

**E. Output.** An analysis submitted to SonarQube, plus `Build-Images/.scannerwork/report-task.txt` in the workspace — which is the input the quality gate function needs.

**F. Why it exists.** Static analysis is one of the two release gates in the project's architecture.

**G. Failure behaviour.** The scanner exits non-zero if it cannot reach the server, cannot authenticate, or cannot find the paths it was told to analyse. That fails the stage. **Note:** a *failing quality gate* does not fail this function — the scanner's job is to submit the analysis, not to judge it.

**H. Relationships.** Depends on `mavenVerify()`. Produces the file `sonarQualityGate()` reads.

---

## 5.4 `sonarQualityGate()`

**A. Purpose.** Determine whether the analysis passed the project's quality gate, and turn that into a pipeline pass or fail.

**B. Inputs.** None; reads `report-task.txt` from the workspace and `SONAR_HOST_URL` from the environment.

**C. Important variables.** `SONAR_TOKEN` again via `withCredentials`.

**D. Commands.** Detailed in Section 12.

**E. Output.** Exit 0 if the gate is `OK`; non-zero otherwise. Prints the verdict prominently.

**F. Why it exists.** Submitting an analysis and never checking the result is theatre. This function is what makes the gate real.

**G. Failure behaviour.** Depends entirely on how it is called:
- `SONAR_GATE=true` → called directly → a failing gate fails the build
- `SONAR_GATE=false` → wrapped in `catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE')` → the verdict is printed, the stage is marked UNSTABLE, and the pipeline continues

**H. Relationships.** Called only from the SonarQube stage, only after `sonarScan()`.

---

## 5.5 `buildImage(img)`

**A. Purpose.** Build one container image with reproducible metadata.

**B. Inputs.** One image map from `IMAGES`.

**C. Important variables.** `params.MAVEN_HEAP`, `env.GIT_SHA`, `env.BUILD_DATE`, `env.TAG`, `env.REPO_URL`.

**D. Commands.** Detailed in Section 13.

**E. Output.** A local image tagged `<name>:<TAG>`, carrying four OCI labels.

**F. Why it exists.** Called five times with different inputs; the flags must be identical every time.

**G. Failure behaviour.** A build failure fails the stage. In sequential mode, later images are not built.

**H. Relationships.** Consumes `env.TAG` from Init. Produces the images `scanImage`, `tagImage`, `pushImage` and the cleanup block all reference.

---

## 5.6 `scanImage(img)`

**A. Purpose.** Three separate jobs in one function: produce a human-readable vulnerability report, produce a machine-readable SBOM, and optionally enforce a security gate.

**B. Inputs.** One image map.

**C. Important variables.** `env.TAG`, `env.TRIVY_CACHE_DIR`, `env.TRIVY_IGNOREFILE`, `params.SECURITY_GATE`, `params.GATE_SEVERITY`.

**D. Commands.** Detailed in Section 14.

**E. Output.** `trivy-<name>.txt` and `sbom-<name>.cdx.json` in the workspace; both archived by the stage's `post` block.

**F. Why it exists.** Supply-chain visibility, plus an enforceable gate.

**G. Failure behaviour.** Parts (a) and (b) fail only on operational errors — they never fail on findings. Part (c) exits 1 when matching vulnerabilities exist, but **only runs when `SECURITY_GATE=true`**.

**H. Relationships.** Runs after Build, before ECR Login. Scans the **local** image, before it is pushed — which is the correct order, because it means a vulnerable image can be stopped before it ever reaches the registry.

---

## 5.7 `tagImage(img)`

```groovy
def tagImage(img) {
    sh "docker tag ${img.name}:${env.TAG} ${env.ECR_REGISTRY}/${img.name}:${env.TAG}"
    if (params.PUSH_LATEST) {
        sh "docker tag ${img.name}:${env.TAG} ${env.ECR_REGISTRY}/${img.name}:latest"
    }
}
```

**A. Purpose.** Give the local image a second name that identifies its destination registry.

**B–D.** `docker tag` creates an **alias**, not a copy. Both names point at the same image ID and the same layers. This costs no disk space and takes no time.

**E. Output.** A registry-qualified reference that `docker push` can act on.

**F. Why it exists.** Docker decides *where* to push from the image name itself. `docker push vprofile-app:tag` would attempt Docker Hub. Only `docker push <account>.dkr.ecr.<region>.amazonaws.com/vprofile-app:tag` targets your ECR.

**G. Failure behaviour.** Fails only if the source image does not exist.

**H. Relationships.** Between Build and Push. Uses `IMAGES.each` — always sequential.

---

## 5.8 `pushImage(img)`

```groovy
def pushImage(img) {
    retry(3) { sh "docker push ${env.ECR_REGISTRY}/${img.name}:${env.TAG}" }
    if (params.PUSH_LATEST) {
        retry(3) { sh "docker push ${env.ECR_REGISTRY}/${img.name}:latest" }
    }
}
```

**A–E.** Uploads layers not already present in ECR, then the manifest. `retry(3)` re-runs the whole command up to three times on failure.

**F. Why the retry.** A push moves hundreds of megabytes over the NAT gateway. A transient TCP reset should not discard a successful build, a passing analysis and a clean scan.

**G. Failure behaviour.** After three attempts, the stage fails. **Important:** `retry` does not distinguish transient from permanent errors — an `ImageTagAlreadyExistsException` will be retried three times and fail three times identically. See Scenario G in Section 25.

**H. Relationships.** Requires ECR Login to have succeeded. Produces what Verify checks.

---

## 5.9 `verifyImage(img)`

```groovy
def verifyImage(img) {
    retry(3) {
        sh """
            aws ecr describe-images --region ${env.AWS_REGION} \
              --repository-name ${img.name} \
              --image-ids imageTag=${env.TAG} \
              --query 'imageDetails[0].imageDigest' --output text
        """
    }
}
```

**A. Purpose.** Independently confirm — by asking AWS, not by trusting the push command's exit code — that the image exists in ECR, and print its digest.

**B–E.** Queries the ECR API for the image with this tag and prints its `imageDigest`, a `sha256:...` content hash. If the tag does not exist, the AWS CLI exits non-zero and the retry loop eventually fails the stage.

**F. Why it exists.** Two reasons. First, **independent verification**: a successful `docker push` exit code is the client's opinion; `describe-images` is the registry's. Second, **traceability**: the digest is printed into the build log, permanently linking build number → git SHA → tag → content hash. Section 18 explains why the digest matters more than the tag.

**G. Failure behaviour.** Retries three times, then fails the stage.

**H. Relationships.** Last stage. Uses `IMAGES.each` — sequential.

---

# 6. Jenkins Configuration — `agent` and `options`

## `agent any`

**[General knowledge]** `agent any` tells Jenkins to run on any available executor. **In this project, no build agents are configured**, so every step — every `docker run`, every `docker build`, every Trivy scan — executes on the **Jenkins controller itself**.

**Practical consequences you should be aware of:**
- Build load competes directly with the Jenkins UI for CPU and memory.
- A build has filesystem access to the Jenkins home directory, including credentials storage.
- The `docker` commands work because the `jenkins` OS user is in the `docker` group.

## `options`

```groovy
options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '15'))
    timeout(time: 90, unit: 'MINUTES')
}
```

| Option | What it does | Why it matters here |
|---|---|---|
| `timestamps()` | Prefixes every console line with a timestamp | Turns "the build was slow" into "the Trivy scan took 4 minutes". Essential for diagnosing a pipeline that pulls images and downloads databases |
| `disableConcurrentBuilds()` | Only one run of this job at a time | **Not cosmetic — required for correctness.** Two concurrent runs would share `/var/lib/jenkins/.m2`, `/var/lib/jenkins/.sonar` and the same Docker daemon. Concurrent Maven writes to one local repository cause corrupt artifacts; concurrent cleanup could delete an image another build is pushing |
| `buildDiscarder(logRotator(numToKeepStr: '15'))` | Keep only the last 15 builds | The archived artifacts (5 Trivy reports + 5 SBOMs per build) accumulate on the 80 GB root volume |
| `timeout(time: 90, unit: 'MINUTES')` | Abort after 90 minutes | The quality gate polls for up to 5 minutes and pushes can stall. Without a timeout, a hung build holds the executor forever and — combined with `disableConcurrentBuilds` — blocks every future run |

Those last two interact: `disableConcurrentBuilds` makes the timeout **necessary**, not merely tidy.

---

# 7. Parameters — One by One

Parameters are inputs a user can change when clicking "Build with Parameters". They are read as `params.NAME`.

### `AWS_REGION` — default `eu-west-3`
**Controls:** which region's ECR and STS endpoints are used.
**Why it exists:** it appears in the registry hostname and in every AWS CLI call.
**When to change:** deploying to another region.
**Affects:** correctness. A wrong value produces a registry hostname that does not exist.

### `IMAGE_TAG` — default `''` (empty)
**Controls:** overrides the automatic tag.
**Why:** to publish a release tag such as `v1.0.3` instead of a build-derived one.
**If left empty:** `<git-sha>-<build-number>` is generated.
**Affects:** correctness and traceability. Because ECR repositories are IMMUTABLE, an explicit tag must be unique or the push fails.

### `GATE_SEVERITY` — default `HIGH,CRITICAL`
**Controls:** which Trivy severities fail the build **when `SECURITY_GATE=true`**.
**Note:** it has **no effect at all** while `SECURITY_GATE=false`.
**Affects:** security.

### `TRIVY_CACHE_DIR` — default `/var/lib/jenkins/.cache/trivy`
**Controls:** where Trivy stores its vulnerability databases.
**Why:** persistence across builds. Without it, every build downloads several hundred megabytes.
**Requirement:** must be writable by the `jenkins` user.
**Affects:** performance.

### `SONAR_CACHE_DIR` — default `/var/lib/jenkins/.sonar`
**Controls:** mounted into the scanner container as `SONAR_USER_HOME`.
**Why:** two reasons — it works around a permission problem in the scanner image (Section 11), and it persists the downloaded scanner engine and JRE between builds.
**Affects:** correctness first, performance second.

### `SONAR_HOST_URL` — default `http://localhost:9000`
**Controls:** the SonarQube server address.
**Why `localhost`:** SonarQube runs as a container on the same EC2 instance, bound to `127.0.0.1:9000`. This is why the scanner container needs `--network host`.
**Affects:** correctness.

### `SONAR_PROJECT_KEY` — default `vprofile`
**Controls:** the project identity in SonarQube; used for both `projectKey` and `projectName`.
**Note:** SonarQube auto-creates the project on first analysis.
**Affects:** correctness — a changed key starts a new project with no history.

### `MAVEN_HEAP` — default `-Xmx1g`
**Controls:** passed as `--build-arg MAVEN_HEAP` into the **app image's Docker build**, where the Dockerfile sets it as `MAVEN_OPTS`.
**Why:** Docker's `--memory` flag is ignored under BuildKit, so the memory limit has to be applied to the JVM itself.

> **Worth knowing:** this parameter controls only the Maven that runs *inside the Docker build*. The `mavenVerify()` function hardcodes `MAVEN_OPTS="-Xmx1g"` on line 55 rather than reading `params.MAVEN_HEAP`. Raising the parameter therefore does **not** raise the heap for the Maven Verify stage. That is an inconsistency in the current source, not a documented behaviour.

### `RUN_SONAR` — default `true` (boolean)
**Controls:** whether Maven Verify and SonarQube run at all.
**When to disable:** debugging the Docker/ECR half of the pipeline quickly.
**Affects:** quality assurance — and build time, substantially.

### `SONAR_GATE` — default `false` (boolean)
**Controls:** whether a failing quality gate **fails the build**.
**`false`:** analysis is published, the verdict is printed, the stage is marked UNSTABLE, and the pipeline continues.
**`true`:** a failing gate stops the pipeline before any image is built.
**Affects:** security and quality enforcement.

### `SKIP_TESTS` — default `false` (boolean)
**Controls:** adds `-DskipTests` to the Maven command.
**Consequence:** no JUnit results and **no JaCoCo coverage data**, so SonarQube reports 0% coverage and any coverage condition in the quality gate will fail.
**The description in the source says it plainly:** "only for debugging the pipeline".

### `SECURITY_GATE` — default `false` (boolean)
**Controls:** whether Trivy's third command — the one with `--exit-code 1` — runs.
**`false`:** scans and SBOMs still run and are still archived; findings never block.
**`true`:** any fixable vulnerability at `GATE_SEVERITY` fails the build before push.
**Affects:** security.

### `PUSH_LATEST` — default `false` (boolean)
**Controls:** whether an additional mutable `latest` tag is created and pushed.
**The source says it must stay false**, and the reason is structural: the ECR repositories are configured `IMMUTABLE` in Terraform. The first push of `latest` succeeds; every subsequent one fails with `ImageTagAlreadyExistsException`. A mutable tag and an immutable repository are fundamentally incompatible.

### `PARALLEL` — default `false` (boolean)
**Controls:** whether Build, Trivy Scan and Push process images concurrently.
**Why the default is `false`:** the comment at line 29 states it — this machine also runs SonarQube, which holds roughly 2.5 GB of JVM heap. Building the Maven-based app image concurrently with the others is what gets OOM-killed first.
**When to enable:** on a dedicated, larger build agent.

## The three flags that are easy to confuse

| | `RUN_SONAR` | `SONAR_GATE` | `SECURITY_GATE` |
|---|---|---|---|
| **Question it answers** | Do we analyse at all? | Does code quality block? | Do vulnerabilities block? |
| **Tool** | Maven + SonarQube | SonarQube | Trivy |
| **Default** | `true` | `false` | `false` |
| **When `false`** | Stages 2 and 3 skipped entirely | Gate advisory only, stage UNSTABLE | Scan and SBOM still produced, no blocking |
| **Stage affected** | Maven Verify, SonarQube | SonarQube | Trivy Scan |

**They are independent.** `RUN_SONAR=true, SONAR_GATE=false` — the current default — means: analyse everything, report everything, block nothing. That is **audit mode**, and it is the correct configuration while bringing a pipeline up. It is not the correct configuration for production.

---

# 8. Environment Variables

```groovy
environment {
    AWS_REGION       = "${params.AWS_REGION}"
    TRIVY_CACHE_DIR  = "${params.TRIVY_CACHE_DIR}"
    TRIVY_IGNOREFILE = "${WORKSPACE}/Build-Images/.trivyignore"
    MAVEN_CACHE      = '/var/lib/jenkins/.m2'
    SONAR_CACHE      = "${params.SONAR_CACHE_DIR}"
    SONAR_HOST_URL   = "${params.SONAR_HOST_URL}"
    REPO_URL         = 'https://github.com/yousefsalemW/DEVSECOPS-PLATFORM-EKS'
}
```

## `params.X` versus `env.X` — the actual difference

| | `params.X` | `env.X` |
|---|---|---|
| **Origin** | The user, at build time | Jenkins, the `environment` block, or `script` assignment |
| **Mutable during the run** | No | Yes — `env.TAG = ...` in Init |
| **Visible to shell commands** | **No** | **Yes** — exported into every `sh` step |
| **Scope** | Groovy code only | Groovy *and* the shell |

**That third row is the whole reason for the conversion.** Consider the ECR Login stage:

```groovy
sh '''
    aws ecr get-login-password --region ${AWS_REGION} \
      | docker login --username AWS --password-stdin ${ECR_REGISTRY}
'''
```

These are **single quotes**, so Groovy does not interpolate. `${AWS_REGION}` is expanded by the **shell**, from the environment. That only works because `AWS_REGION` was copied from `params` into `environment`. Had the pipeline written `${params.AWS_REGION}` there, the shell would have substituted an empty string.

This distinction — Groovy interpolation with `"""` versus shell expansion with `'''` — is also a security control. See Section 24.

## Each variable

| Variable | Value | Consumed by |
|---|---|---|
| `AWS_REGION` | from params | ECR Login (shell), `verifyImage`, `ECR_REGISTRY` construction |
| `TRIVY_CACHE_DIR` | from params | all four Trivy invocations |
| `TRIVY_IGNOREFILE` | `${WORKSPACE}/Build-Images/.trivyignore` | Trivy report and gate — **not** the SBOM |
| `MAVEN_CACHE` | `/var/lib/jenkins/.m2` (hardcoded) | `mavenVerify` |
| `SONAR_CACHE` | from params | `sonarScan` |
| `SONAR_HOST_URL` | from params | `sonarScan` and, via the shell, `sonarQualityGate` |
| `REPO_URL` | hardcoded | the `image.source` OCI label |

**Why `TRIVY_IGNOREFILE` is absolute.** Trivy looks for `.trivyignore` in its **current working directory**, which is the workspace root. The file actually lives at `Build-Images/.trivyignore`. Without this explicit absolute path, Trivy would silently find nothing and every documented, accepted CVE would count against the gate.

Variables created later, in the Init stage, and available to all subsequent stages: `GIT_SHA`, `BUILD_DATE`, `TAG`, `AWS_ACCOUNT_ID`, `ECR_REGISTRY`.

---

# 9. Stage 1 — Init

```groovy
env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse --short=8 HEAD').trim()
env.BUILD_DATE = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
env.TAG        = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim()
                                          : "${env.GIT_SHA}-${env.BUILD_NUMBER}"

env.AWS_ACCOUNT_ID = sh(returnStdout: true,
    script: 'aws sts get-caller-identity --query Account --output text').trim()
env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"

sh "mkdir -p ${env.TRIVY_CACHE_DIR}"
retry(3) { sh "trivy image --cache-dir ${env.TRIVY_CACHE_DIR} --download-db-only" }
retry(3) { sh "trivy image --cache-dir ${env.TRIVY_CACHE_DIR} --download-java-db-only" }
```

## `GIT_SHA`

`git rev-parse --short=8 HEAD` prints the first 8 characters of the current commit hash, e.g. `a3f9c2d1`. `sh(returnStdout: true)` captures stdout rather than just running the command; `.trim()` removes the trailing newline.

**This works only because Jenkins checked out the repository into the workspace.** The job must be configured as "Pipeline script from SCM". With the script pasted directly into the job, there is no `.git` directory and this line fails immediately.

## `TAG` — the most important value in the pipeline

```groovy
env.TAG = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim() : "${env.GIT_SHA}-${env.BUILD_NUMBER}"
```

`?.` is Groovy's safe-navigation operator — if `IMAGE_TAG` is null it returns null instead of throwing. The ternary then means: *use the supplied tag if it is non-empty; otherwise generate one.*

**Concrete examples:**

| Run | `IMAGE_TAG` | `GIT_SHA` | `BUILD_NUMBER` | Resulting `TAG` |
|---|---|---|---|---|
| 1 | *(empty)* | `a3f9c2d1` | 7 | `a3f9c2d1-7` |
| 2 | *(empty)* | `a3f9c2d1` | 8 | `a3f9c2d1-8` |
| 3 | *(empty)* | `b7e4f0a9` | 9 | `b7e4f0a9-9` |
| 4 | `v1.0.3` | `b7e4f0a9` | 10 | `v1.0.3` |

**Why the git SHA alone is not enough.** The ECR repositories are IMMUTABLE: a tag, once pushed, can never be reused. Runs 1 and 2 are the *same commit* — a re-run after fixing an unrelated infrastructure problem, or a retry after a network failure. With a bare SHA both would produce `a3f9c2d1`, and the second push would fail with `ImageTagAlreadyExistsException`. Appending `BUILD_NUMBER` — which Jenkins increments monotonically and never reuses — guarantees uniqueness while keeping the commit visible in the tag.

**The tag therefore encodes both facts you need during an incident:** *which code* (`a3f9c2d1`) and *which build produced it* (`7`).

## `AWS_ACCOUNT_ID` and `ECR_REGISTRY`

`aws sts get-caller-identity` asks AWS "who am I?" and returns the account ID, user ID and ARN. `--query Account` extracts just the account number.

**Why query it at runtime rather than hardcode it?** Three reasons: the pipeline works unchanged in any account; there is no account number committed to a public repository; and the call **doubles as a credential health check** — if the instance profile is broken, this fails in Init with a clear message rather than five stages later during push.

`ECR_REGISTRY` is then assembled into AWS's fixed registry hostname format:

```
450444046673.dkr.ecr.eu-west-3.amazonaws.com
└──account──┘     └─region─┘
```

## Trivy database pre-warming

```groovy
retry(3) { sh "trivy image --cache-dir ... --download-db-only" }
retry(3) { sh "trivy image --cache-dir ... --download-java-db-only" }
```

Trivy needs two databases: the general vulnerability database, and a separate Java database for identifying JAR files by their content.

**Why download them here, once.** Later, `scanImage` runs **three** Trivy commands per image (two when the security gate is off) across five images — up to 15 invocations. Without pre-warming, each one would check for and potentially download database updates. Pre-warming means one download per build instead of fifteen checks.

**How the two halves connect.** Every scan command later uses `--skip-db-update`, which tells Trivy "use what is in the cache, do not check for updates". That flag is only safe *because* Init guaranteed the cache is fresh. **The two are a matched pair — removing the pre-warm while keeping `--skip-db-update` would mean scanning against a stale or empty database, which could silently report zero vulnerabilities.**

`retry(3)` is here because this is a network download and the pipeline is worthless if it fails.

## The summary banner

The `echo """..."""` block prints registry, tag, git SHA, and the effective mode of each gate. **This is genuinely useful operationally:** six months later, looking at build #47, you can see at a glance whether the gates were enforced or in audit mode for that run.

---

# 10. Stage 2 — Maven Verify, in depth

## Why Java 11

The application is a Spring 5 / Java EE (`javax.*`) application whose `pom.xml` targets Java 11. `maven:3.9.9-eclipse-temurin-11` is chosen to match **exactly** the JDK used inside the app image's own Dockerfile build stage. If the two differed, the bytecode analysed by SonarQube would not be the bytecode shipped in the image.

## Why Maven runs in a container rather than on the host

1. **The host stays clean.** The Jenkins EC2 does not need a JDK 11 or a Maven installation. Its `jenkins-userdata.sh` installs JDK 21 for Jenkins itself — a completely different version.
2. **Version pinning.** The Maven and JDK versions are declared in the pipeline, not in a host bootstrap script that runs once at instance creation.
3. **Reproducibility.** Any machine with Docker produces an identical build environment.
4. **Consistency with the image build.** The same base image is used in both places.

## Why the workspace is mounted at `/src`

The container starts empty. `-v "${WORKSPACE}/Build-Images":/src` makes the source visible inside it, and `-w /src` sets that as the working directory so `mvn` finds `pom.xml`.

**Crucially, a bind mount is bidirectional.** Everything Maven writes into `target/` inside the container appears in `Build-Images/target/` in the Jenkins workspace, and survives the container's deletion by `--rm`. **That is the entire point** — the output is the deliverable, not the container.

## Why `.m2` is mounted and why `MAVEN_CACHE` exists

`MAVEN_CACHE = '/var/lib/jenkins/.m2'` is a directory on the host that persists between builds. Mounted at `/var/maven/.m2` inside the container, it is where Maven stores every downloaded dependency.

Without it, `--rm` would delete the entire local repository after every build, and the next build would re-download the complete dependency tree — several hundred megabytes, over the NAT gateway, every single time.

## The permission problem — why `-u`, `HOME`, `MAVEN_CONFIG` and `-Duser.home` all exist together

This group of flags solves one problem, and it is worth understanding as a whole.

**The problem.** By default a container runs as **root**. Root inside the container writes files owned by UID 0 into the bind-mounted workspace. The Jenkins process — running as the unprivileged `jenkins` user — then cannot delete or overwrite them. The next build fails during workspace cleanup or during checkout, with a permission error that has nothing to do with the actual change being built. This is a classic, confusing and self-inflicted CI failure.

**The fix, and its consequence.** `-u $(id -u):$(id -g)` runs the container as the calling user, so output is owned by `jenkins`. But dropping root breaks something else: the container's `/root` directory is not writable by an arbitrary UID, and Maven wants to write to `$HOME/.m2`.

That is why three more settings are required:

| Setting | Fixes |
|---|---|
| `-e HOME=/var/maven` | Where the **shell and most tools** look for the home directory |
| `-e MAVEN_CONFIG=/var/maven/.m2` | Where **Maven** looks for its settings |
| `-Duser.home=/var/maven` | Where the **JVM** looks — Java reads the `user.home` system property, not `$HOME` |

All three are needed because three different layers each resolve "home" their own way. Removing any one of them produces a different, confusing failure.

## Why `MAVEN_OPTS="-Xmx1g"`

Maven's JVM will otherwise size its heap from the machine's total memory. On an 8 GB instance that also runs Jenkins (1.5 GB heap) and SonarQube (~2.5 GB across three JVMs), an unbounded Maven can trigger the kernel OOM killer — which will terminate the largest process, and that is usually SonarQube's Elasticsearch. Losing SonarQube's search index is a much worse outcome than a slow build.

## What `mvn verify` actually does

**[General knowledge]** Maven lifecycle phases run cumulatively — requesting `verify` runs everything before it:

```
validate → compile → test → package → integration-test → verify
```

For this project that means:
- `compile` → `target/classes/`
- `test` → runs the 5 test classes; JUnit XML in `target/surefire-reports/`
- `package` → the WAR in `target/`
- **JaCoCo's `report` goal is bound to `post-integration-test`**, which is why `verify` is the correct phase and `mvn test` would **not** be sufficient — it would stop before coverage was written

## What changes with `SKIP_TESTS=true`

`-DskipTests` is appended. Tests compile but do not run. Therefore:
- No `target/surefire-reports/*.xml` → the `junit` step publishes nothing (it tolerates this via `allowEmptyResults: true`)
- **No `target/site/jacoco/jacoco.xml`** → SonarQube receives no coverage data and reports 0%
- If the quality gate has a coverage condition, it will fail

## How Maven output reaches SonarQube

Both containers mount **the same host directory**:

```
Host: ${WORKSPACE}/Build-Images
  ├── mounted at /src      in the Maven container      → writes target/
  └── mounted at /usr/src  in the scanner container    → reads target/
```

The workspace is the handoff mechanism. Nothing is copied; the two containers simply see the same files.

---

# 11. Stage 3a — SonarQube Analysis

## The Java 11 versus Java 17 problem

Three facts collide:

1. The application must be compiled with **Java 11** (it uses `javax.*` APIs and targets 11).
2. Modern SonarQube Scanner requires **Java 17 or later** to run.
3. `mvn sonar:sonar` would run the scanner inside the same JVM that compiled the code.

You cannot satisfy all three in one container. **The pipeline's solution: split the work in two.**

```
Container 1: maven:3.9.9-eclipse-temurin-11
  Job: compile + test + coverage
  Output: target/classes, target/test-classes, surefire-reports, jacoco.xml
                    ↓ (via the shared workspace)
Container 2: sonarsource/sonar-scanner-cli  (ships its own Java 17+)
  Job: read those outputs, analyse, upload
```

**Why this separation is genuinely useful beyond solving the version conflict:**
- The scanner is upgraded independently of the build toolchain
- The build container stays minimal — no scanner dependencies
- The same pattern works for any language: compile in the language's own image, analyse in the scanner's

## The scanner container

```groovy
docker run --rm \
  -u $(id -u):$(id -g) \
  --network host \
  -v "${WORKSPACE}/Build-Images":/usr/src \
  -v ${SONAR_CACHE}:/sonar-cache \
  -e SONAR_USER_HOME=/sonar-cache \
  -e SONAR_HOST_URL=${SONAR_HOST_URL} \
  -e SONAR_TOKEN \
  sonarsource/sonar-scanner-cli:latest \
    -Dsonar.working.directory=/usr/src/.scannerwork \
    ...
```

### `--network host`

The container shares the host's network namespace, so `localhost` inside the container **is** the host's localhost. SonarQube is bound to `127.0.0.1:9000`. Without this flag the container gets its own network namespace, `localhost` refers to the container itself, and the connection is refused.

### `-e SONAR_TOKEN` with no value

Note the form: `-e SONAR_TOKEN`, not `-e SONAR_TOKEN=$SONAR_TOKEN`.

**[General knowledge]** Docker supports passing a variable *by name*, in which case it reads the value from the environment of the process invoking `docker run`. Since `withCredentials` has already placed `SONAR_TOKEN` in the shell's environment, this form works — **and the secret never appears on the command line**, so it is not visible in `ps` output on the host. This is a deliberate hardening choice.

### `SONAR_USER_HOME` — a real permission bug, worked around

The comment in the source is precise: the scanner image ships its cache at `/opt/sonar-scanner/.sonar`, owned by the image's own UID 1000. Running with `-u <jenkins-uid>` means that directory is not writable, and the scanner fails with `AccessDenied` on `/opt/sonar-scanner/.sonar/cache` — **before analysing anything**.

Redirecting `SONAR_USER_HOME` to a bind-mounted host directory solves it, and gains a second benefit: the scanner downloads its analysis engine and a JRE on first run, and mounting the cache means those are downloaded **once**, not on every build.

### `sonar.working.directory` — the subtle one

The scanner's default working directory in this image is `/tmp/.scannerwork`, which has the same ownership problem — `AccessDenied` on `/tmp/.scannerwork/.sonartmp`.

But there is a second, more important reason to redirect it into the mounted workspace. The scanner writes `report-task.txt` into its working directory. `sonarQualityGate()` reads that file from `Build-Images/.scannerwork/report-task.txt` **in the workspace**. If it were written to `/tmp` inside the container, `--rm` would delete it along with the container, and the quality gate would fail every time with "no report-task.txt".

**These two mounts are not optimisations. Without them the stage does not work at all.**

## The `-Dsonar.*` properties

| Property | Value | What it does |
|---|---|---|
| `sonar.projectKey` | `params.SONAR_PROJECT_KEY` | Unique project identity; auto-created on first analysis |
| `sonar.projectName` | same | Display name |
| `sonar.projectVersion` | `env.TAG` | **Links the analysis to the exact image tag.** Six months later you can look up the analysis for `a3f9c2d1-7` |
| `sonar.sources` | `src/main` | Application code to analyse |
| `sonar.tests` | `src/test` | Test code — analysed with different rules |
| `sonar.java.binaries` | `target/classes` | **Compiled application bytecode** |
| `sonar.java.test.binaries` | `target/test-classes` | Compiled test bytecode |
| `sonar.junit.reportPaths` | `target/surefire-reports` | Test results |
| `sonar.coverage.jacoco.xmlReportPaths` | `target/site/jacoco/jacoco.xml` | Coverage |
| `sonar.scm.revision` | `env.GIT_SHA` | Ties the analysis to the commit |

### Why the scanner needs `target/classes`

**[General knowledge]** SonarQube's Java analyser does not work from source text alone. It builds a semantic model — resolving types, following method calls across classes, understanding inheritance — and that requires compiled bytecode. Given only source, it degrades to shallow lexical checks and reports an error about missing binaries.

**This is the hard dependency that makes the whole Maven Verify stage necessary.** `target/classes` is the reason it exists. Remove Maven Verify and the SonarQube stage still runs, but the analysis is nearly worthless.

`target/test-classes` serves the parallel purpose for test code, and is what lets Sonar distinguish "this is a test" from "this is production code" when applying rules.

---

# 12. Stage 3b — The Quality Gate

## Three terms that are commonly confused

| Term | What it is |
|---|---|
| **Analysis** | The scanner reading your code and **uploading** the results. Ends when the upload completes |
| **Compute Engine (CE) task** | Server-side **background processing** of that upload — computing issues, coverage, duplication, and the gate verdict. Queued, and takes time |
| **Quality Gate** | The **pass/fail verdict**: a set of conditions (coverage ≥ X, no new blocker issues, ...) evaluated against the processed analysis |

**This ordering is why polling is required.** When `sonarScan()` returns, the analysis has been *uploaded* but not necessarily *processed*. Asking for the gate verdict immediately would return nothing useful.

## Why not the Jenkins plugin

**[General knowledge]** The usual approach is the SonarQube Scanner for Jenkins plugin's `waitForQualityGate()` step. It works by having SonarQube send a **webhook back to Jenkins** when processing completes.

**Why this project deliberately does not use it** — two concrete reasons rooted in this architecture:

1. **No plugin dependency.** The pipeline works on any Jenkins with no plugin installed and no plugin version to keep compatible.
2. **No inbound webhook needed.** Jenkins runs on a private subnet with **no inbound security group rules**. A webhook is an inbound HTTP call. Here SonarQube is on the same host so a webhook to `localhost:8080` would technically work — but the polling approach has no such coupling at all, and the entire gate logic stays visible in the Jenkinsfile rather than hidden in plugin configuration.

## The seven steps

```bash
# 1. Locate the scanner's output
REPORT="Build-Images/.scannerwork/report-task.txt"
[ -f "${REPORT}" ] || { echo "no ${REPORT} — did the scan run?"; exit 1; }
```
Fails immediately and clearly if the scan did not run or wrote elsewhere.

```bash
# 2. Extract the CE task id
TASK_ID=$(awk -F= '/^ceTaskId=/{print $2}' "${REPORT}")
```
`report-task.txt` is a small key=value file the scanner writes containing `ceTaskId`, `ceTaskUrl`, `projectKey` and `serverUrl`. `awk -F=` splits on `=` and prints the value of the matching line.

```bash
# 3-4. Poll until processing completes — up to 60 × 5s = 5 minutes
for _ in $(seq 1 60); do
  STATUS=$(curl -sS -u "${SONAR_TOKEN}:" "${SONAR_HOST_URL}/api/ce/task?id=${TASK_ID}" | jq -r '.task.status')
  case "${STATUS}" in
    SUCCESS)         break ;;
    FAILED|CANCELED) echo "SonarQube analysis ${STATUS}"; exit 1 ;;
  esac
  sleep 5
done
[ "${STATUS}" = "SUCCESS" ] || { echo "timed out waiting for analysis"; exit 1; }
```

- `-u "${SONAR_TOKEN}:"` — SonarQube's API accepts a token as the HTTP Basic **username** with an empty password. The trailing colon is required.
- `-sS` — silent, but still show errors.
- `jq -r` — extract the field as a raw string.
- The `case` distinguishes three outcomes: done, failed, still running.
- The explicit check after the loop matters: without it, a timeout would fall through and the next command would query with an empty analysis ID.

```bash
# 5. Get the analysis id
ANALYSIS_ID=$(curl ... | jq -r '.task.analysisId')
```
Only populated once the task has succeeded — which is why this comes after the loop.

```bash
# 6-7. Ask for the verdict and enforce it
GATE=$(curl -sS -u "${SONAR_TOKEN}:" \
  "${SONAR_HOST_URL}/api/qualitygates/project_status?analysisId=${ANALYSIS_ID}" \
  | jq -r '.projectStatus.status')
[ "${GATE}" = "OK" ]
```

That last line is the whole gate. In shell, the exit status of the final command is the exit status of the script. `[ "$GATE" = "OK" ]` exits 0 when the gate passed and 1 otherwise — so `sh` fails the step. Elegant, and with no extra `if`.

`set -eu` at the top means any unexpected failure or unset variable also aborts.

## `SONAR_GATE=false` versus `true`

```groovy
if (params.SONAR_GATE) {
    sonarQualityGate()                                   // failure fails the build
} else {
    echo 'SONAR_GATE=false → analysis published, verdict not enforced'
    catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
        sonarQualityGate()                               // failure marks UNSTABLE only
    }
}
```

**Note that the gate function runs in both branches.** The difference is only in how its failure is treated.

**Why `catchError` rather than skipping the check entirely?** Because you still want to *see* the verdict. `catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE')` catches the exception, keeps the overall build green, and marks the stage yellow in the UI. The verdict is printed in the log and visible in the stage view — you get the information without the enforcement. That is precisely what "audit mode" should mean.

---

# 13. Stage 4 — Docker Build

```groovy
sh """
    DOCKER_BUILDKIT=1 docker build --pull \
      --build-arg MAVEN_HEAP=${params.MAVEN_HEAP} \
      --label org.opencontainers.image.revision=${env.GIT_SHA} \
      --label org.opencontainers.image.created=${env.BUILD_DATE} \
      --label org.opencontainers.image.version=${env.TAG} \
      --label org.opencontainers.image.source=${env.REPO_URL} \
      -f ${img.file} \
      -t ${img.name}:${env.TAG} \
      ${img.ctx}
"""
```

## `DOCKER_BUILDKIT=1` — and the honest caveat in the source

**[General knowledge]** BuildKit is Docker's modern build engine: parallel stage execution, better caching, and improved secret handling.

**The Jenkinsfile's own comment (lines 153–157) documents something important:** this environment variable only takes effect if the **buildx plugin** is installed. Ubuntu's `docker.io` package ships **without** it, so Docker silently falls back to the legacy builder and emits a deprecation warning in the console log.

**The distinction worth internalising:**
- `DOCKER_BUILDKIT=1` — a *request* to use BuildKit
- `docker-buildx` — the *plugin* that actually provides it

Setting the variable without installing the plugin does nothing. This is honest documentation of a real gap, and it is also why the `MAVEN_HEAP` approach below is the right one either way.

## `--pull`

Always re-fetch the base image from its registry rather than using a locally cached copy.

**Why this is a security control, not just hygiene.** `mysql:8.0.43` is a tag, and tags can be repushed — vendors regularly rebuild patch releases with updated OS packages. Without `--pull`, a stale local copy could be reused for months, so a base-image CVE fixed upstream would never reach your images even though your scans keep passing. `--pull` costs a registry check per build and guarantees you build on the current content of that tag.

## `--build-arg MAVEN_HEAP` — and why not `--memory`

The intuitive way to limit a build's memory is `docker build --memory=2g`. **That does not work under BuildKit** — BuildKit accepts the flag and ignores it, because resource limits apply to the buildkit worker, not per-build.

So the limit is applied one layer down: the value is passed as a build argument, and the app's Dockerfile turns it into `MAVEN_OPTS`, which the JVM does honour.

**Why this is the more robust choice regardless of the BuildKit situation:** it works identically under the legacy builder and under BuildKit. Relying on `--memory` would mean the limit silently stops working the day someone installs `docker-buildx`.

## OCI labels

**[General knowledge]** The OCI image specification defines standard `org.opencontainers.image.*` annotation keys so that tooling can read image metadata in a consistent way.

| Label | Value | Answers the question |
|---|---|---|
| `revision` | `env.GIT_SHA` | **Which commit is this?** |
| `created` | `env.BUILD_DATE` | **When was it built?** |
| `version` | `env.TAG` | **Which release?** |
| `source` | `env.REPO_URL` | **Where is the source?** |

**Why this matters practically.** During an incident you have a running container and a question: what code is this? `docker inspect` on the image returns the commit hash directly. Without labels you would be reverse-engineering it from tags and build logs.

```bash
docker inspect <image> --format '{{json .Config.Labels}}'
```

## `-f`, `-t` and the context

- `-f ${img.file}` — the Dockerfile, path relative to the workspace
- `-t ${img.name}:${env.TAG}` — the local image name, e.g. `vprofile-app:a3f9c2d1-7`
- `${img.ctx}` — the final positional argument: the build context

Note that `-t` produces a **local** name with no registry prefix. Making it push-ready is the Tag stage's job.

---

# 14. Stage 5 — Trivy Scan and SBOM

`scanImage()` runs **three** commands per image (two when the gate is off). They have genuinely different purposes.

## Part A — the HIGH/CRITICAL report

```groovy
trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
  --ignorefile ${env.TRIVY_IGNOREFILE} \
  --no-progress --ignore-unfixed --skip-db-update \
  --severity HIGH,CRITICAL --format table \
  --output trivy-${img.name}.txt ${ref}
```

| Flag | Meaning | Why |
|---|---|---|
| `--cache-dir` | Use the persistent cache | Populated in Init |
| `--ignorefile` | Path to the accepted-risk list | Absolute, because Trivy runs from the workspace root and the file lives in `Build-Images/` |
| `--no-progress` | Suppress the progress bar | Progress bars in a non-TTY log are noise |
| `--ignore-unfixed` | Hide vulnerabilities with no available fix | Focus on what is actionable |
| `--skip-db-update` | Do not check for DB updates | Init already refreshed it |
| `--severity HIGH,CRITICAL` | Filter | The rest is background noise for triage purposes |
| `--format table --output` | Human-readable, to a file | Archived as a build artifact |

**Why this command never fails the build.** There is no `--exit-code`. Trivy's default exit code is 0 regardless of findings. This command is purely informational — its product is the artifact.

**A nuance worth knowing about `--ignore-unfixed`:** the report shows only vulnerabilities with an available fix. Unfixed HIGH/CRITICAL CVEs exist and are simply not shown. That is a defensible triage decision — you cannot act on them today — but it means this report is not a complete picture of risk.

## Part B — the SBOM

```groovy
trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
  --no-progress --skip-db-update \
  --format cyclonedx \
  --output sbom-${img.name}.cdx.json ${ref}
```

**[General knowledge]** An **SBOM** (Software Bill of Materials) is a machine-readable inventory of every component in an artifact — OS packages, language libraries, versions, licences. **CycloneDX** is one of the two dominant standard formats.

**Why it matters.** When the next Log4Shell-class vulnerability is announced, the question is "are we affected, and where?". Without SBOMs you rescan every image and hope. With SBOMs you query a file.

**Note the two flags that are deliberately absent:**
- **No `--severity`** — an SBOM is an inventory, not a vulnerability report
- **No `--ignorefile`** — and the source comments say why: *"an SBOM must list every component"*

That second point is a genuinely good decision. Filtering an SBOM through an ignore list would produce a document that claims a component is not present when it is. The ignore file expresses *"we accept this risk"*, which is a statement about vulnerabilities. It has no business modifying an inventory.

## Part C — the security gate

```groovy
if (params.SECURITY_GATE) {
    trivy image --cache-dir ... --ignorefile ... \
      --no-progress --ignore-unfixed --skip-db-update \
      --severity ${params.GATE_SEVERITY} --exit-code 1 ${ref}
}
```

The single meaningful difference from Part A: **`--exit-code 1`**. Trivy now exits 1 if any matching vulnerability is found, which fails the `sh` step, which fails the stage.

**Exactly when Trivy blocks the pipeline:**

| `SECURITY_GATE` | Findings | Result |
|---|---|---|
| `false` | any | Report + SBOM archived. **Never blocks** |
| `true` | none matching | Passes |
| `true` | fixable at `GATE_SEVERITY`, not in `.trivyignore` | **Build fails before push** |
| `true` | all matches listed in `.trivyignore` | Passes |

**The ordering is the point.** The scan runs on the **local** image, before ECR Login. A vulnerable image is stopped before it ever reaches the registry — so ECR never contains an image that failed the gate.

---

# 15. Stage 6 — ECR Authentication

## The complete credential chain

```
Jenkins pipeline runs `aws` CLI
        ↓
AWS SDK credential provider chain looks for credentials:
  env vars? → shared config file? → ... → EC2 Instance Metadata Service
        ↓
IMDSv2 on 169.254.169.254 (token-required, enforced in Terraform)
        ↓
EC2 Instance Profile attached to the instance
        ↓
IAM Role: jenkins-ec2-role
   ├── AmazonEC2ContainerRegistryPowerUser  (ECR read/write)
   ├── AmazonSSMManagedInstanceCore         (SSM access)
   └── inline: eks:DescribeCluster, eks:ListClusters, sts:GetCallerIdentity
        ↓
Temporary credentials, auto-rotated by AWS
        ↓
ECR API
```

**Why no static access key is needed.** The AWS SDK automatically discovers credentials from the instance metadata service. The credentials it receives are **temporary** and **automatically rotated** — there is nothing to store, nothing to leak, and nothing to rotate manually.

The file header states this explicitly:

> `ECR auth uses the instance profile (jenkins-ec2-role → ECR PowerUser), so no AWS credentials are stored in Jenkins.`

**And this is verifiable:** grep the repository for `AWS_ACCESS_KEY_ID` or `aws_secret_access_key` and you find nothing.

## The login command

```groovy
retry(3) {
    sh '''
        aws ecr get-login-password --region ${AWS_REGION} \
          | docker login --username AWS --password-stdin ${ECR_REGISTRY}
    '''
}
```

**Step by step:**

1. `aws ecr get-login-password` — calls the ECR API using the instance-profile credentials and returns a temporary authorisation token (valid 12 hours). It prints it to **stdout**.
2. `|` — pipes it directly to the next command. **The token never becomes a shell variable, never appears in a command line, and never touches disk.**
3. `docker login --username AWS --password-stdin <registry>` — the username is literally the string `AWS` for ECR; `--password-stdin` reads the password from standard input.

**Why `--password-stdin` rather than `--password <value>`.** With `--password`, the token would appear in the full command line — visible to any user running `ps aux` on the host, and potentially captured into shell history or a process-accounting log. `--password-stdin` is the documented, correct way, and Docker itself prints a warning when you use `--password`.

**Note the single quotes.** `sh '''...'''` means Groovy does not interpolate; `${AWS_REGION}` and `${ECR_REGISTRY}` are expanded by the shell from the environment. Consistent with the pattern in Section 8.

**Why `retry(3)`.** This is a network call over the NAT gateway. A transient failure here would waste everything already computed.

---

# 16. Stage 7 — Tagging

## Local name versus registry-qualified name

```
Local:  vprofile-app:a3f9c2d1-7
ECR:    450444046673.dkr.ecr.eu-west-3.amazonaws.com/vprofile-app:a3f9c2d1-7
        └────────────── registry ──────────────────┘ └── repo ──┘ └── tag ──┘
```

**[General knowledge]** Docker determines the destination registry by parsing the image name. A name with no registry prefix defaults to Docker Hub. So `docker push vprofile-app:a3f9c2d1-7` would attempt to push to Docker Hub — and fail, or worse, succeed if such a repository existed.

`docker tag` creates an **alias**: a second name for the same image ID. No layers are copied, no disk is consumed, and it is instantaneous.

## `PUSH_LATEST` and why it must stay false

```groovy
if (params.PUSH_LATEST) {
    sh "docker tag ${img.name}:${env.TAG} ${env.ECR_REGISTRY}/${img.name}:latest"
}
```

The parameter description states: *"MUST stay false — the ECR repos are IMMUTABLE (see terraform)"*.

**The incompatibility is structural, not stylistic.** A mutable tag like `latest` works by being *reassigned* to a new image on every release. An IMMUTABLE ECR repository forbids reassigning any tag. So:

- Build #7 pushes `latest` → succeeds
- Build #8 pushes `latest` → `ImageTagAlreadyExistsException`

Every subsequent build would fail at the Push stage.

**And immutability is worth keeping.** It is what guarantees that the image you scanned in stage 5 is byte-for-byte the image running in production. With mutable tags, `vprofile-app:v1.0` could be silently replaced after passing every gate — which defeats the entire scanning pipeline.

---

# 17. Stage 8 — Push

```groovy
retry(3) { sh "docker push ${env.ECR_REGISTRY}/${img.name}:${env.TAG}" }
```

**What actually happens.** Docker computes the digest of each layer, asks the registry which it already has, uploads only the missing ones, then uploads the manifest. Because the five images share base layers with previous builds, subsequent pushes are much faster than the first.

**Why `retry(3)`.** Pushing five images moves hundreds of megabytes through a NAT gateway. A transient failure at this point would discard a successful build, a passing analysis and a clean scan.

**A limitation to be aware of:** `retry` treats all failures identically. A permanent error — the tag already exists, or the repository does not — is retried three times and fails three times with the same message. The retry is useful for network faults and harmless otherwise, but it does not make the pipeline smart about error types.

**The `latest` push**, when `PUSH_LATEST=true`, is also wrapped in `retry(3)` — and will still fail on the second build, for the reasons in Section 16.

---

# 18. Stage 9 — Verification

```groovy
aws ecr describe-images --region ${env.AWS_REGION} \
  --repository-name ${img.name} \
  --image-ids imageTag=${env.TAG} \
  --query 'imageDetails[0].imageDigest' --output text
```

## Tag versus digest

**[General knowledge]**

| | Tag | Digest |
|---|---|---|
| Example | `a3f9c2d1-7` | `sha256:9f2c...` |
| Nature | A human-assigned **label** | A **cryptographic hash of the content** |
| Can point elsewhere later | Yes (unless the repo is immutable) | **Never** |
| Guarantees content | No | **Yes** |

A digest is derived from the image manifest, which references every layer by its own hash. Change one byte in one layer and the digest changes. **The digest is an identity; the tag is a name.**

## Why printing it matters

Two distinct benefits:

1. **Independent confirmation.** A successful `docker push` exit code is the *client's* report. `describe-images` asks the *registry* whether the image is actually there. If the tag is missing, the CLI exits non-zero and the stage fails.

2. **A permanent traceability record.** The build log now contains a complete chain:

```
Build #7  →  commit a3f9c2d1  →  tag a3f9c2d1-7  →  digest sha256:9f2c...
```

When a container is running in production six months later, `kubectl describe pod` shows the digest it is actually running. Search the build logs for that digest and you have the exact build, the exact commit, the exact Trivy report and the exact SBOM. **This is what "traceability" concretely means**, and it is why the digest is stronger evidence than the tag alone.

---

# 19. Post — Cleanup

```groovy
post {
    always {
        script {
            IMAGES.each { img ->
                sh """
                    docker rmi -f ${img.name}:${env.TAG}                       || true
                    docker rmi -f ${env.ECR_REGISTRY}/${img.name}:${env.TAG}   || true
                    docker rmi -f ${env.ECR_REGISTRY}/${img.name}:latest       || true
                """
            }
            sh 'docker image prune -f || true'
            sh 'docker builder prune -f --keep-storage 10GB || true'
            sh 'docker logout ${ECR_REGISTRY} || true'
        }
    }
    success { echo "All images pushed to ${env.ECR_REGISTRY} with tag ${env.TAG}" }
    failure { echo "Pipeline failed — check the Trivy artifacts and the console log" }
}
```

## Why `post { always { } }`

**[General knowledge]** `post` runs after all stages, and `always` runs regardless of outcome — success, failure or abort.

**Why cleanup must be here rather than in a final stage.** The failure case is precisely when cleanup matters most. If the Push stage fails on the fourth of five images, the first three are still on disk. If cleanup were a stage, it would never run — and disk usage would grow on every failed build until the volume filled and *every* build started failing for an unrelated reason.

## The commands

| Command | Purpose |
|---|---|
| `docker rmi -f <name>:<tag>` | Remove the local tag. Both the local and ECR-qualified names must be removed — they are two names for one image, and it is deleted only when the last name is gone |
| `docker image prune -f` | Remove dangling images — layers left over from intermediate build stages |
| `docker builder prune -f --keep-storage 10GB` | Trim the **build cache**, keeping up to 10 GB. Note this is deliberately *not* a full purge: the recent cache is what makes the next build fast |
| `docker logout` | Discard the ECR credential from `~/.docker/config.json`. A 12-hour token should not sit on disk after the build |

## Why every command ends in `|| true`

**[General knowledge]** In shell, `cmd || true` means "run cmd; if it fails, run `true` instead" — and `true` always succeeds. The net effect is that the failure is swallowed.

**Why this is the right choice here.** Consider a build that succeeded completely — all five images built, scanned, pushed and verified. Then cleanup runs, and `docker rmi` fails because an image was never created (the pipeline failed early) or is in use. Without `|| true`, that cleanup failure would **turn a successful build red**.

That would be actively harmful: it reports a false failure, hides the real result, and trains you to ignore red builds. Cleanup is housekeeping — it must never change the verdict on the actual work.

**The trade-off, stated honestly:** if cleanup genuinely stops working, the pipeline will not tell you. You would notice indirectly, through disk usage.

## `success` and `failure`

Simple `echo` statements. Note the failure message points at the Trivy artifacts, which are archived by the Trivy stage's own `post { always { } }` block and therefore exist **even when the build later failed** — so a build that failed at the security gate still leaves you the reports explaining why.

> **This is not implemented in the current Jenkinsfile:** there is no email, Slack or other external notification. The `success`/`failure` blocks only write to the console log.

---

# 20. Parallel versus Sequential

## What `PARALLEL` changes

Three stages iterate with `forEachImage` and therefore respect the flag: **Build**, **Trivy Scan**, **Push**.

Two stages use `IMAGES.each` and are **always sequential**: **Tag** and **Verify**. Both are fast metadata operations where parallelism would gain nothing.

## Why the default is `false`

The comment at line 29 states the reason directly: this machine also runs SonarQube, which holds roughly 2.5 GB of JVM heap across three processes.

**The memory arithmetic on an 8 GB instance:**

```
SonarQube (web + CE + Elasticsearch)   ~2.5 GB
Jenkins JVM                             1.5 GB
OS + Docker daemon                     ~0.5 GB
────────────────────────────────────────────────
Remaining for builds                   ~3.5 GB
```

Sequential: one Maven JVM at a time, capped at 1 GB. Comfortable.

Parallel: the app image's Maven build runs **at the same time as** four other builds, each pulling and extracting base images. Memory demand spikes well past what remains, and the kernel OOM killer selects the largest process — which is SonarQube's Elasticsearch. Losing that corrupts the search index and SonarQube needs a rebuild.

**So the failure mode is not "the build is slow" — it is "an unrelated service on the box is destroyed".** That is why the default is conservative.

## When parallel becomes appropriate

- On a dedicated build agent that does **not** host SonarQube
- On an instance with substantially more memory
- If image builds are moved to Kubernetes pod agents, where each gets its own resource limits

**[General knowledge]** Jenkins' `parallel` step defaults to `failFast: false`, so one failing branch does not stop the others. The stage fails once all branches complete.

---

# 21. Complete Data Flow

```
┌─ SOURCE ──────────────────────────────────────────────────────────┐
│  GitHub repository (public)                                       │
│    Build-Images/{pom.xml, src/, images/*/Dockerfile, .trivyignore} │
│    docker/web/{Dockerfile, nginx.conf}                            │
│    Jenkinsfile                                                    │
└───────────────────────────┬───────────────────────────────────────┘
                            │ Pipeline from SCM checkout
                            ↓
┌─ IDENTITY (Init) ─────────────────────────────────────────────────┐
│  git rev-parse --short=8 HEAD  ──────────▶  GIT_SHA = a3f9c2d1    │
│  Jenkins BUILD_NUMBER          ──────────▶  7                     │
│                                             ╰──▶ TAG = a3f9c2d1-7 │
│  aws sts get-caller-identity   ──────────▶  ACCOUNT_ID            │
│  params.AWS_REGION             ──────────▶  eu-west-3             │
│                                             ╰──▶ ECR_REGISTRY     │
│  trivy --download-db-only + --download-java-db-only → cache warm   │
└───────────────────────────┬───────────────────────────────────────┘
                            ↓
┌─ QUALITY ─────────────────────────────────────────────────────────┐
│  maven:3.9.9-eclipse-temurin-11                                   │
│     └─▶ target/classes · test-classes · surefire · jacoco.xml     │
│              │                                                     │
│              ↓ (same host directory, different mount point)        │
│  sonar-scanner-cli  ──▶  SonarQube :9000  ──▶  CE task            │
│              │                                    │                │
│              ↓                                    ↓                │
│     .scannerwork/report-task.txt  ──▶ poll ──▶ Quality Gate       │
│                                                 OK / ERROR         │
│                                    SONAR_GATE=true → block         │
└───────────────────────────┬───────────────────────────────────────┘
                            ↓
┌─ PACKAGE ─────────────────────────────────────────────────────────┐
│  docker build --pull  × 5   (OCI labels: revision/created/        │
│                              version/source)                      │
│     └─▶ vprofile-{app,db,mc,rmq,web}:a3f9c2d1-7   (local)         │
└───────────────────────────┬───────────────────────────────────────┘
                            ↓
┌─ SECURITY ────────────────────────────────────────────────────────┐
│  per image:                                                        │
│    (a) trivy → trivy-<name>.txt        (report, never blocks)      │
│    (b) trivy → sbom-<name>.cdx.json    (full inventory)            │
│    (c) trivy --exit-code 1             [SECURITY_GATE only]        │
│  both artifacts archived by Jenkins                                │
└───────────────────────────┬───────────────────────────────────────┘
                            ↓
┌─ PUBLISH ─────────────────────────────────────────────────────────┐
│  instance profile ▶ STS ▶ ECR token ▶ docker login --password-stdin│
│  docker tag  ──▶  <registry>/<name>:a3f9c2d1-7                     │
│  docker push (retry 3)                                             │
│  aws ecr describe-images  ──▶  sha256:9f2c...   ← DIGEST           │
└───────────────────────────┬───────────────────────────────────────┘
                            ↓
                    ═══ CI ENDS HERE ═══
```

---

# 22. CI versus CD — where this pipeline stops

## What this Jenkinsfile does — CI

Build · test · analyse · package · scan · publish.

## What it does not do — CD

> **This is not implemented in the current Jenkinsfile.**
>
> Verified by inspection of the 423-line source:
> - occurrences of `helm`: **0**
> - occurrences of `kubectl`: **0**
> - stages that touch Kubernetes: **none**
> - rollback logic: **none**
> - deployment verification: **none**

The pipeline's final act is confirming an image digest in ECR. Deployment is a **separate, manual operation** performed on the Jenkins host over SSM.

## The boundary, drawn precisely

```
╔══════════════ CI — automated by this Jenkinsfile ═════════════╗
║  Git → Init → Maven → Sonar → Build → Trivy → ECR → Verify    ║
╚═══════════════════════════════════════════════════════════════╝
                              │
                              │  ◀── the tag is the handoff
                              │      (currently carried by a human)
                              ↓
╔══════════════ CD — currently manual ══════════════════════════╗
║  helm upgrade --install vprofile helm/vprofile \              ║
║    --set image.registry=<registry> \                          ║
║    --set image.tag=a3f9c2d1-7 \                               ║
║    --set db.existingSecret=db01-credentials                   ║
╚═══════════════════════════════════════════════════════════════╝
```

**The two halves are joined by exactly one value: the image tag.** CI produces it; CD consumes it. Everything else about the handoff is convention.

**What that manual boundary costs, stated plainly:** no automatic record of what was deployed and by whom; no guarantee that the tag deployed is a tag that passed the gates; no enforced rollback path. Those are real gaps — but they are gaps in *this file*, and describing them as anything else would be inaccurate.

---

# 23. Helm Integration

The project contains a Helm chart at `helm/vprofile/`. **The Jenkinsfile does not invoke it.** The relationship is entirely by convention — but the conventions are deliberate and they line up exactly.

## Where the two halves meet

```
Jenkinsfile                          Helm chart
───────────                          ──────────
env.ECR_REGISTRY        ────────▶    --set image.registry=...
                                          ↓
                                     .Values.image.registry

env.TAG                 ────────▶    --set image.tag=...
                                          ↓
                                     .Values.image.tag

IMAGES[].name           ═══════▶     hardcoded in the templates:
  vprofile-app                         "vprofile-app"
  vprofile-db                          "vprofile-db"
  vprofile-mc                          "vprofile-mc"
  vprofile-rmq                         "vprofile-rmq"
  vprofile-web                         "vprofile-web"
```

The chart's `_helpers.tpl` defines a function that assembles these three pieces:

```
<registry>/<name>:<tag>
```

which reconstructs precisely the reference this pipeline pushed:

```
450444046673.dkr.ecr.eu-west-3.amazonaws.com/vprofile-app:a3f9c2d1-7
```

**The five image names are a contract between the two files.** They are not passed as data — they are written independently in both places and must match. Rename an image in `IMAGES` without renaming it in the chart templates and the deployment fails with `ImagePullBackOff`.

## The `required` guard

The chart's image helper uses Helm's `required` function on both `image.registry` and `image.tag`. If either is missing, `helm template` **fails during rendering** rather than deploying a broken reference.

This matters for the eventual Deploy stage: a pipeline that forgot to pass `--set image.tag` would get a clear error instead of silently deploying whatever was there before.

## `db.existingSecret`

The chart supports `db.existingSecret`, which points at a Kubernetes Secret created **outside** the chart. When set, the chart creates no Secret of its own and contains no credential.

**Relationship to this pipeline: none, and that is correct.** The database password is an **application runtime secret**. It is created out-of-band with `kubectl create secret` and never appears in the pipeline, the chart, or Git. The pipeline handles only **CI credentials** — the Sonar token and ECR authentication. Section 24 draws this distinction out.

---

# 24. Security Architecture

Every item below is verifiable in the uploaded source.

## What is actually implemented

### 1. No static AWS credentials
**Evidence:** no `AWS_ACCESS_KEY_ID`, no `aws_secret_access_key`, no `withCredentials` binding for AWS anywhere in the file. All AWS calls rely on the EC2 instance profile.
**Why it matters:** there is no long-lived key to leak, rotate, or accidentally commit.

### 2. ECR authentication via short-lived token, piped through stdin
**Evidence:** `aws ecr get-login-password | docker login --password-stdin`
**Why:** the token is valid 12 hours, never appears on a command line, never becomes a shell variable, and never touches disk before Docker consumes it.

### 3. The Sonar token is bound, not stored
**Evidence:** `withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')])`
**Why:** the value lives in Jenkins' credential store, is injected only inside the block, and Jenkins masks it in the console output.

### 4. The token is not exposed on the command line
**Evidence:** `-e SONAR_TOKEN` — passed by name, not by value.
**Why:** the value never appears in the `docker run` command line, so it is not visible via `ps aux` on the host.

### 5. Groovy interpolation is avoided where it would leak
**Evidence:** `sonarQualityGate()` uses `sh '''...'''` (single quotes). `${SONAR_TOKEN}` is expanded by the **shell**, from the environment.
**Why this is a real control:** with `"""` (double quotes), **Groovy** would substitute the token into the string *before* the shell ever sees it — and Jenkins would print that expanded command into the console log. Single quotes are what keep it out.

### 6. Immutable tags with guaranteed uniqueness
**Evidence:** `TAG = <git-sha>-<BUILD_NUMBER>`, `PUSH_LATEST` defaulting false with an explanatory description.
**Why:** the image that was scanned is provably the image that gets deployed. Nothing can be silently replaced after passing the gates.

### 7. Scan before push
**Evidence:** the Trivy Scan stage precedes ECR Login.
**Why:** with the gate enabled, a vulnerable image never reaches the registry.

### 8. SBOM per image
**Evidence:** the CycloneDX output in `scanImage()`, archived as an artifact.
**Why:** answers "are we affected?" for a future CVE without rescanning.

### 9. Traceability via OCI labels and digest verification
**Evidence:** four `--label org.opencontainers.image.*` flags; `aws ecr describe-images --query imageDigest`.
**Why:** a running container can be traced back to a commit.

### 10. Base image freshness
**Evidence:** `--pull` on every build.
**Why:** upstream base-image CVE fixes are picked up rather than a stale local copy being reused.

## CI credentials versus application runtime secrets

This distinction is worth being explicit about, because conflating them is a common source of confusion.

| | CI credentials | Application runtime secrets |
|---|---|---|
| **Examples** | Sonar token, ECR token | Database password, RabbitMQ credentials |
| **Who uses them** | The pipeline, at build time | The running application, in Kubernetes |
| **Where they live** | Jenkins credential store; instance profile | Kubernetes Secret (later: Vault) |
| **In this Jenkinsfile** | **Yes — handled correctly** | **No — and correctly absent** |

**The pipeline handles zero application secrets, and that is the right design.** A CI system that needs the production database password is a CI system with an unnecessarily large blast radius.

## What is not implemented — stated plainly

> **These are not implemented in the current Jenkinsfile:**
> - Image signing (no `cosign` — SBOMs prove *content*, signatures would prove *origin*)
> - Both gates default to `false`, so nothing currently blocks
> - The scanner image is `sonarsource/sonar-scanner-cli:latest` — unpinned, so the build is not fully reproducible and a compromised upstream tag would execute in your pipeline
> - No branch protection or approval gate
> - No secret scanning of the source (Trivy scans images, not the repository)

---

# 25. Failure Scenarios

For each: which stage fails, and what runs afterwards.

### Scenario A — Maven fails (compilation error or failing test)

**Fails at:** Maven Verify.
**Then:** `post { always { junit ... } }` still publishes whatever test results exist, so you can see which test failed. **All subsequent stages are skipped.** Cleanup runs — the `docker rmi` commands find nothing and are swallowed by `|| true`.
**Nothing is built or pushed.** This is correct: code that does not compile should never become an image.

### Scenario B — SonarQube is unreachable

**Fails at:** SonarQube, inside `sonarScan()`. The scanner cannot connect to `http://localhost:9000` and exits non-zero.
**Then:** the pipeline stops. Build, Trivy and Push never run.
**Diagnosis:** the SonarQube container is not running, or `--network host` is missing.
**Note:** `SONAR_GATE=false` does **not** help here. The `catchError` wraps only the gate function, not the scan.
**Workaround for an urgent build:** `RUN_SONAR=false` skips both quality stages entirely.

### Scenario C — Analysis succeeds but the quality gate fails

**With `SONAR_GATE=false`** (the current default): `sonarQualityGate()` exits non-zero, `catchError` intercepts it, the stage is marked **UNSTABLE** (yellow), the verdict is printed, and **the pipeline continues**. Images are built and pushed.

**With `SONAR_GATE=true`:** the stage **fails**. Nothing is built or pushed.

**The verdict is printed in both cases** — the difference is only in enforcement.

### Scenario D — Trivy finds HIGH/CRITICAL vulnerabilities

**With `SECURITY_GATE=false`** (current default) — *audit mode*: parts (a) and (b) produce the report and SBOM, part (c) never runs. The stage **passes**. Vulnerable images are pushed to ECR. You learn about the findings by reading the archived artifact.

**With `SECURITY_GATE=true`** — *enforced*: part (c) exits 1, the stage **fails**, and ECR Login, Tag, Push and Verify are all skipped. **The vulnerable image never reaches the registry.**

**The essential difference:** audit mode produces *information*; enforced mode produces a *decision*. Findings listed in `.trivyignore` pass in both modes.

### Scenario E — ECR login fails

**Fails at:** ECR Login, after three retry attempts.
**Likely causes:** the instance profile is missing or lacks ECR permissions; the region is wrong; no network path to the ECR endpoint.
**Then:** Tag, Push and Verify are skipped. The five built images exist locally and are removed by cleanup.
**Note:** if the credentials were broken, `aws sts get-caller-identity` in Init would usually have failed first — which is one of the reasons that call is useful.

### Scenario F — Docker push fails

**Fails at:** Push, after three attempts on the affected image.
**Sequential mode:** images earlier in the list were already pushed successfully. **This leaves ECR in a partial state** — some images at the new tag, some not. There is no rollback; the fix is to resolve the cause and re-run, which produces a new `BUILD_NUMBER` and therefore a new tag.
**Then:** Verify is skipped. Cleanup runs.

### Scenario G — ECR reports the tag already exists

**Error:** `ImageTagAlreadyExistsException`, at Push.
**Cause:** the repository is IMMUTABLE and this exact tag was pushed before. In practice this happens when `IMAGE_TAG` was set explicitly to a value already used, or `PUSH_LATEST=true` on a second build.
**Behaviour:** `retry(3)` retries and fails identically three times — the retry cannot help with a permanent error.
**Fix:** leave `IMAGE_TAG` empty so `BUILD_NUMBER` guarantees uniqueness, and keep `PUSH_LATEST=false`.

### Scenario H — Cleanup fails

**Result: nothing.** Every cleanup command ends in `|| true`, so failures are swallowed and the build's verdict is unchanged. This is intentional — housekeeping must never turn a successful build red.
**The trade-off:** a persistently failing cleanup is invisible. You would notice it indirectly, as disk usage.

### Scenario I — Docker runs out of disk space

**Fails at:** whichever stage is running — most likely Build (extracting layers) or Push.
**Why it can happen:** five images, plus base images, plus BuildKit cache, plus the Maven cache, plus SonarQube's data, on one 80 GB volume.
**Mitigations already present:** `docker image prune -f` and `docker builder prune -f --keep-storage 10GB` in cleanup, plus `buildDiscarder` limiting archived artifacts to 15 builds.
**Note:** cleanup runs *after* the failure, so it often frees the space that the *next* build needs — meaning the failure may not repeat, which can make this problem look intermittent.

### Scenario J — The pipeline exceeds 90 minutes

**Result:** `timeout(time: 90, unit: 'MINUTES')` aborts the build.
**Then:** `post { always { } }` still runs, so cleanup happens.
**Why the timeout is essential:** with `disableConcurrentBuilds()`, a hung build would otherwise block every subsequent run indefinitely.
**Realistic causes:** the quality gate polling loop (bounded at 5 minutes), a stalled push, or a very slow first build downloading the entire Maven dependency tree.

---

# 26. End-to-End Walkthrough — one image

## `vprofile-app`, from source to digest

Assume commit `a3f9c2d1`, Jenkins build `#7`, defaults everywhere.

**1 · Source**
`Build-Images/src/main/java/...`, `pom.xml`, `images/app/Dockerfile`. Jenkins checks these out into the workspace.

**2 · Init**
`GIT_SHA=a3f9c2d1` · `TAG=a3f9c2d1-7` · `ECR_REGISTRY=450444046673.dkr.ecr.eu-west-3.amazonaws.com` · Trivy databases refreshed.

**3 · Maven Verify**
A `maven:3.9.9-eclipse-temurin-11` container runs `mvn -B verify` against `/src`. Writes into the workspace: `target/classes/`, `target/test-classes/`, `target/surefire-reports/*.xml`, `target/site/jacoco/jacoco.xml`, and the WAR. JUnit results published to Jenkins.

**4 · SonarQube**
A `sonar-scanner-cli` container mounts the same directory at `/usr/src`, reads `target/classes` and the coverage report, and uploads the analysis to `localhost:9000`. Writes `.scannerwork/report-task.txt`. `sonarQualityGate()` extracts the CE task ID, polls until `SUCCESS`, fetches the verdict, prints it. With the default `SONAR_GATE=false`, a failing verdict marks the stage UNSTABLE and the pipeline continues.

**5 · Build**
```
DOCKER_BUILDKIT=1 docker build --pull \
  --build-arg MAVEN_HEAP=-Xmx1g \
  --label org.opencontainers.image.revision=a3f9c2d1 \
  ... \
  -f Build-Images/images/app/Dockerfile \
  -t vprofile-app:a3f9c2d1-7 \
  Build-Images
```
The Dockerfile's own multi-stage build compiles the application **again**, inside the image, and produces a Tomcat image running as `USER tomcat`.

**6 · Trivy**
- `trivy-vprofile-app.txt` — fixable HIGH/CRITICAL findings, minus `.trivyignore`
- `sbom-vprofile-app.cdx.json` — every component, unfiltered
- Gate skipped (`SECURITY_GATE=false`)
Both files archived.

**7 · Local image**
`vprofile-app:a3f9c2d1-7` exists on the Docker daemon.

**8 · Tag**
`docker tag vprofile-app:a3f9c2d1-7 450444046673.dkr.ecr.eu-west-3.amazonaws.com/vprofile-app:a3f9c2d1-7` — an alias, instant, no disk used.

**9 · Push**
Layers not already in ECR are uploaded, then the manifest.

**10 · Verify**
`aws ecr describe-images ... --query imageDetails[0].imageDigest` prints `sha256:9f2c...` into the build log.

**11 · Cleanup**
Both local names removed; dangling images pruned; build cache trimmed to 10 GB; `docker logout`.

**Final result:** `450444046673.dkr.ecr.eu-west-3.amazonaws.com/vprofile-app:a3f9c2d1-7` @ `sha256:9f2c...`, with labels tying it to commit `a3f9c2d1`, a Trivy report, an SBOM, and a SonarQube analysis versioned `a3f9c2d1-7`.

## The other four, in brief

| Image | Differences from the walkthrough above |
|---|---|
| `vprofile-db` | Same context (`Build-Images`, for `db_backup.sql`). **No Maven involvement** — Stages 3 and 4 concern only the app's source. Everything from Build onward is identical |
| `vprofile-mc` | Context narrowed to `Build-Images/images/memcached` — copies nothing, so the context is nearly empty. Fastest build |
| `vprofile-rmq` | Context narrowed to its own directory. Same pattern |
| `vprofile-web` | Context `docker/web`, needs `nginx.conf`. The only image outside `Build-Images/` |

**Note:** Maven Verify and SonarQube analyse the **application source only**. The other four images contain no project-authored code — they are patched upstream images with configuration. They are still built, scanned, SBOM'd, pushed and verified identically.

---

# 27. Vocabulary

| Term | Definition | Where it appears here |
|---|---|---|
| **Pipeline** | The complete automated workflow | The `pipeline { }` block |
| **Stage** | A named phase, shown as a column in the Jenkins UI | The nine `stage(...)` blocks |
| **Step** | A single action inside a stage | `sh`, `echo`, `retry`, `junit` |
| **Agent** | Where steps execute | `agent any` — the controller, since no agents are configured |
| **Parameter** | A user-supplied input, read as `params.X` | The 14 in `parameters { }` |
| **Environment variable** | A value available to Groovy **and** the shell, read as `env.X` | The `environment { }` block plus values set in Init |
| **Closure** | A block of code passed as an argument | `{ img -> buildImage(img) }` |
| **Helper function** | A reusable Groovy function defined outside the pipeline | The nine functions in lines 31–237 |
| **Workspace** | The per-job directory holding the checkout and build outputs | `${WORKSPACE}`, mounted into both containers |
| **Build context** | The directory tree sent to the Docker daemon | The `ctx` field of each `IMAGES` entry |
| **BuildKit** | Docker's modern build engine | `DOCKER_BUILDKIT=1` — inert without the buildx plugin |
| **Multi-stage build** | A Dockerfile with several `FROM` stages, where build tools are discarded | The app image builds with Maven, ships Tomcat |
| **Maven** | Java build tool; runs cumulative lifecycle phases | `mvn verify` in a container |
| **SonarQube** | Static analysis server for code quality and security | `localhost:9000` |
| **Compute Engine task** | SonarQube's server-side background processing of an upload | Polled via `/api/ce/task` |
| **Quality Gate** | The pass/fail verdict from SonarQube's conditions | `/api/qualitygates/project_status` |
| **Trivy** | Vulnerability and misconfiguration scanner | 3 invocations per image (2 with the gate off), plus 2 pre-warms in Init |
| **SBOM** | Machine-readable inventory of an artifact's components | `sbom-*.cdx.json` |
| **CycloneDX** | A standard SBOM format | `--format cyclonedx` |
| **ECR** | AWS's private container registry | 5 immutable repositories |
| **IAM Instance Profile** | An IAM role attached to an EC2 instance, granting automatic temporary credentials | How every AWS call authenticates |
| **Image tag** | A human-assigned label | `a3f9c2d1-7` |
| **Image digest** | A cryptographic hash of the image content | `sha256:9f2c...`, printed by Verify |
| **OCI labels** | Standard image metadata keys | 4 labels per image |
| **Retry** | A Jenkins step that re-runs a block on failure | `retry(3)` — DB download, login, push, verify |
| **Artifact** | A file saved by Jenkins and attached to the build | Trivy reports and SBOMs |
| **`post` block** | Actions after stages complete | `always` cleanup, `success`, `failure` |
| **`catchError`** | Catch a failure and downgrade its severity | Used to make the Sonar gate advisory |

---

# 28. Final Mental Model

Memorise this shape:

```
Jenkins       orchestrates and provides identity (git sha + build number).
Git           supplies the source and the commit hash.
Maven         compiles and tests in a JDK 11 container — the workspace
              becomes the handoff medium.
SonarQube     analyses that compiled bytecode; a separate Java 17 container
              runs the scanner; the gate verdict is polled, not pushed.
Docker        packages five images with --pull and OCI provenance labels.
Trivy         reports, inventories (SBOM), and — when enabled — blocks.
IAM           authenticates to AWS with no stored credential anywhere.
ECR           stores the images under an immutable, unique tag.
Verification  asks the registry, not the client, and records the digest.
Cleanup       always runs, and never changes the verdict.

CI ends at the digest. CD is manual, and the image tag is the handoff.
```

## The four ideas that explain most of the design

**1. The workspace is the integration point.**
Maven writes `target/`; the scanner reads it. Two containers, one host directory. No copying, no artifact server. Understand this and the container flags make sense.

**2. Uniqueness is enforced by construction, not by discipline.**
`<git-sha>-<build-number>` against IMMUTABLE repositories means the image scanned is provably the image deployed. Nothing can be silently replaced after passing the gates.

**3. Gates are separate from analysis, on purpose.**
`RUN_SONAR` decides whether to look. `SONAR_GATE` and `SECURITY_GATE` decide whether to act. Splitting them allows a pipeline to be brought up in audit mode and hardened afterwards — which is what the current defaults represent.

**4. Credentials are borrowed, never stored.**
The instance profile provides AWS access; `withCredentials` provides the Sonar token for one block only. Nothing long-lived exists to leak — and the shell-versus-Groovy quoting choices exist to keep it that way.

---

*Written from the uploaded `Jenkinsfile` (423 lines). Where behaviour is absent from that source, it is marked as not implemented rather than described.*
