// =============================================================================
//  DEVSECOPS-PLATFORM-EKS — Quality/Build/Scan/Push Pipeline
//  ALnaqib · DevOps Engineer
//
//  Stages:  Init → Maven Verify → SonarQube (+ quality gate) → Build
//           → Trivy Scan (+ SBOM) → ECR Login → Tag → Push → Verify → Cleanup
//
//  Requirements on the Jenkins node:
//    - docker with BuildKit (jenkins user in the docker group)
//    - trivy, jq, git, aws cli v2
//    - SonarQube reachable on SONAR_HOST_URL (localhost:9000 on this box)
//    - Jenkins credential 'sonar-token' (secret text) = a SonarQube user token
//  ECR auth uses the instance profile (jenkins-ec2-role → ECR PowerUser),
//  so no AWS credentials are stored in Jenkins.
// =============================================================================

// Map of each image: name (= ECR repo name) + Dockerfile + build context
def IMAGES = [
    [name: 'vprofile-app', file: 'Build-Images/images/app/Dockerfile',       ctx: 'Build-Images'],
    [name: 'vprofile-db',  file: 'Build-Images/images/db/Dockerfile',        ctx: 'Build-Images'],
    [name: 'vprofile-mc',  file: 'Build-Images/images/memcached/Dockerfile', ctx: 'Build-Images/images/memcached'],
    [name: 'vprofile-rmq', file: 'Build-Images/images/rabbitmq/Dockerfile',  ctx: 'Build-Images/images/rabbitmq'],
    [name: 'vprofile-web', file: 'docker/web/Dockerfile',                     ctx: 'docker/web'],
]

// -------- helpers -----------------------------------------------------------

// Run a closure over every image, sequentially or in parallel.
// NOTE: this box also runs SonarQube (~2.5 GB of JVM heap), so a parallel build
// of the Maven app image is what gets OOM-killed first. Keep PARALLEL=false.
def forEachImage(List images, boolean parallelMode, Closure body) {
    if (parallelMode) {
        parallel images.collectEntries { img -> ["${img.name}", { body(img) }] }
    } else {
        images.each { body(it) }
    }
}

// The app image compiles Maven INSIDE its own multi-stage Dockerfile, so the
// Jenkins workspace never holds target/classes. SonarQube's Java analyser needs
// that bytecode, so compile once here in the SAME JDK 11 image the Dockerfile
// uses, and hand the output to the scanner.
//   -u  : write build output as the jenkins user, not root, or the next
//         workspace cleanup fails on root-owned files
//   HOME/-Duser.home: required once we drop root, since /root/.m2 is unwritable
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

// The scanner CLI needs Java 17+, while the app is built on Java 11 — so it runs
// as its own container rather than as a maven goal in the build above.
// --network host: SonarQube is bound to 127.0.0.1:9000 on this same instance.
//
// Two paths inside this image are NOT writable by an arbitrary -u uid, and both
// have to be redirected or the scanner dies before it analyses anything:
//
//   SONAR_USER_HOME         the image ships its cache at /opt/sonar-scanner/.sonar
//                           owned by the image's own uid 1000 → AccessDenied on
//                           /opt/sonar-scanner/.sonar/cache. Bind-mounted from the
//                           host here, which also persists the downloaded scanner
//                           engine + JRE between builds instead of re-fetching them.
//   sonar.working.directory the image default is /tmp/.scannerwork, which already
//                           exists in the image and is likewise not ours →
//                           AccessDenied on /tmp/.scannerwork/.sonartmp.
//                           Pointing it INTO the mounted workspace is what the
//                           quality gate needs anyway: sonarQualityGate() reads
//                           Build-Images/.scannerwork/report-task.txt from the
//                           workspace, and anything written under /tmp would
//                           vanish with --rm.
def sonarScan() {
    withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
        sh """
            mkdir -p ${env.SONAR_CACHE}
            docker run --rm \
              -u \$(id -u):\$(id -g) \
              --network host \
              -v "${env.WORKSPACE}/Build-Images":/usr/src \
              -v ${env.SONAR_CACHE}:/sonar-cache \
              -e SONAR_USER_HOME=/sonar-cache \
              -e SONAR_HOST_URL=${env.SONAR_HOST_URL} \
              -e SONAR_TOKEN\
              sonarsource/sonar-scanner-cli:latest \
                -Dsonar.working.directory=/usr/src/.scannerwork \
                -Dsonar.projectKey=${params.SONAR_PROJECT_KEY} \
                -Dsonar.projectName=${params.SONAR_PROJECT_KEY} \
                -Dsonar.projectVersion=${env.TAG} \
                -Dsonar.sources=src/main \
                -Dsonar.tests=src/test \
                -Dsonar.java.binaries=target/classes \
                -Dsonar.java.test.binaries=target/test-classes \
                -Dsonar.junit.reportPaths=target/surefire-reports \
                -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml \
                -Dsonar.scm.revision=${env.GIT_SHA}
        """
    }
}

// Plugin-free quality gate: poll the Compute Engine task, then read the gate
// verdict. Deliberately not using waitForQualityGate() so the pipeline needs no
// Jenkins plugin and no SonarQube webhook back into Jenkins.
def sonarQualityGate() {
    withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
        sh '''
            set -eu
            REPORT="Build-Images/.scannerwork/report-task.txt"
            [ -f "${REPORT}" ] || { echo "no ${REPORT} — did the scan run?"; exit 1; }

            TASK_ID=$(awk -F= '/^ceTaskId=/{print $2}' "${REPORT}")
            echo "CE task: ${TASK_ID}"

            STATUS=""
            for _ in $(seq 1 60); do
              STATUS=$(curl -sS -u "${SONAR_TOKEN}:" \
                "${SONAR_HOST_URL}/api/ce/task?id=${TASK_ID}" | jq -r '.task.status')
              echo "  analysis: ${STATUS}"
              case "${STATUS}" in
                SUCCESS)         break ;;
                FAILED|CANCELED) echo "SonarQube analysis ${STATUS}"; exit 1 ;;
              esac
              sleep 5
            done
            [ "${STATUS}" = "SUCCESS" ] || { echo "timed out waiting for analysis"; exit 1; }

            ANALYSIS_ID=$(curl -sS -u "${SONAR_TOKEN}:" \
              "${SONAR_HOST_URL}/api/ce/task?id=${TASK_ID}" | jq -r '.task.analysisId')

            GATE=$(curl -sS -u "${SONAR_TOKEN}:" \
              "${SONAR_HOST_URL}/api/qualitygates/project_status?analysisId=${ANALYSIS_ID}" \
              | jq -r '.projectStatus.status')

            echo "===================================="
            echo " QUALITY GATE: ${GATE}"
            echo "===================================="
            [ "${GATE}" = "OK" ]
        '''
    }
}

def buildImage(img) {
    echo "==> build ${img.name}:${env.TAG}"
    // --pull        : always fetch the latest base image (covers base-image CVEs)
    // BuildKit      : faster builds + better layer cache. NOTE: this only takes
    //                 effect if the buildx plugin is installed; the Ubuntu
    //                 docker.io package ships without it and silently falls back
    //                 to the legacy builder (see the deprecation warning in the
    //                 console log). Install docker-buildx to get real BuildKit.
    // OCI labels    : git sha / build date / version for audit & traceability
    // MAVEN_HEAP    : caps the Maven JVM inside the app build. NOTE: docker's
    //                 --memory flag is silently IGNORED under BuildKit, so the
    //                 limit has to be applied to the JVM itself, not the builder.
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
}

def scanImage(img) {
    def ref = "${img.name}:${env.TAG}"
    echo "==> Trivy ${ref}"

    // (a) HIGH+CRITICAL report — archived as an artifact, never fails the build.
    //     --skip-db-update: DB was pre-warmed in Init, so no per-image download.
    //     --ignorefile    : the accepted-risk list lives under Build-Images/, but
    //                       trivy runs from the workspace root and would never
    //                       find it on its own.
    sh """
        trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
          --ignorefile ${env.TRIVY_IGNOREFILE} \
          --no-progress --ignore-unfixed --skip-db-update \
          --severity HIGH,CRITICAL --format table \
          --output trivy-${img.name}.txt ${ref}
    """

    // (b) SBOM in CycloneDX format — archived per image.
    //     No ignorefile here on purpose: an SBOM must list every component.
    sh """
        trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
          --no-progress --skip-db-update \
          --format cyclonedx \
          --output sbom-${img.name}.cdx.json ${ref}
    """

    // (c) Security gate — fails the build on fixable findings at GATE_SEVERITY.
    if (params.SECURITY_GATE) {
        sh """
            trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
              --ignorefile ${env.TRIVY_IGNOREFILE} \
              --no-progress --ignore-unfixed --skip-db-update \
              --severity ${params.GATE_SEVERITY} --exit-code 1 ${ref}
        """
    }
}

def tagImage(img) {
    sh "docker tag ${img.name}:${env.TAG} ${env.ECR_REGISTRY}/${img.name}:${env.TAG}"
    if (params.PUSH_LATEST) {
        sh "docker tag ${img.name}:${env.TAG} ${env.ECR_REGISTRY}/${img.name}:latest"
    }
}

def pushImage(img) {
    // retry: a transient network blip must not kill the whole pipeline.
    retry(3) { sh "docker push ${env.ECR_REGISTRY}/${img.name}:${env.TAG}" }
    if (params.PUSH_LATEST) {
        retry(3) { sh "docker push ${env.ECR_REGISTRY}/${img.name}:latest" }
    }
}

def verifyImage(img) {
    // Confirm the image really landed in ECR and print its digest (traceability).
    retry(3) {
        sh """
            aws ecr describe-images --region ${env.AWS_REGION} \
              --repository-name ${img.name} \
              --image-ids imageTag=${env.TAG} \
              --query 'imageDetails[0].imageDigest' --output text
        """
    }
}


// -------- deployment ---------------------------------------------------------

// Refuse to deploy unless the cluster is reachable AND the credential Secret the
// chart expects already exists. Both failures are cheap to detect here and
// expensive to diagnose later: a missing Secret renders fine and only shows up
// as CreateContainerConfigError minutes into the rollout.
def preflight() {
    sh """
        mkdir -p \$(dirname "\${KUBECONFIG}")
        aws eks update-kubeconfig \
          --name ${params.CLUSTER_NAME} \
          --region ${env.AWS_REGION} \
          --kubeconfig "\${KUBECONFIG}"

        kubectl version --request-timeout=20s -o json > /dev/null
        kubectl get nodes --no-headers | awk '{print "  node " \$1 " " \$2}'
    """

    // Both credentials are required by the chart (db.existingSecret and
    // rabbitmq.existingSecret). Checked here rather than left to helm, because
    // a missing Secret otherwise surfaces a minute into the render as a template
    // failure with no hint about which one, or how to create it.
    [
        [name: params.DB_SECRET_NAME,  value: 'db.existingSecret',       keys: "--from-literal=MYSQL_ROOT_PASSWORD='<strong password>'"],
        [name: params.RMQ_SECRET_NAME, value: 'rabbitmq.existingSecret', keys: "--from-literal=RABBITMQ_DEFAULT_USER='vprofile' \\\n    --from-literal=RABBITMQ_DEFAULT_PASS='<strong password>'"],
    ].each { sec ->
        def missing = sh(returnStatus: true, script: """
            kubectl -n ${params.K8S_NAMESPACE} get secret ${sec.name} > /dev/null 2>&1
        """)
        if (missing != 0) {
            error("""Secret '${sec.name}' not found in namespace '${params.K8S_NAMESPACE}'.
The chart requires it (${sec.value}) and will not render without it. Create it once:
  kubectl -n ${params.K8S_NAMESPACE} create secret generic ${sec.name} \\
    ${sec.keys}""")
        }
    }
}

// Render the chart and print it before applying anything. This is the artifact
// that answers "what exactly did build #47 deploy?" six months from now.
def renderManifests() {
    sh """
        helm template ${params.HELM_RELEASE} helm/vprofile \
          --namespace ${params.K8S_NAMESPACE} \
          --set image.registry=${env.ECR_REGISTRY} \
          --set image.tag=${env.TAG} \
          --set db.existingSecret=${params.DB_SECRET_NAME} \
          --set rabbitmq.existingSecret=${params.RMQ_SECRET_NAME} \
          > rendered-${env.TAG}.yaml
        echo "rendered \$(grep -c '^kind:' rendered-${env.TAG}.yaml) objects"
    """
}

// --atomic is safe HERE but was deliberately avoided during the first manual
// deploy: on failure it rolls back and deletes the very pods you need to
// inspect. Now that the deployment is known-good, automatic rollback is what we
// want -- a failed pipeline must never leave a half-updated release running.
def deployRelease() {
    sh """
        helm upgrade --install ${params.HELM_RELEASE} helm/vprofile \
          --namespace ${params.K8S_NAMESPACE} --create-namespace \
          --set image.registry=${env.ECR_REGISTRY} \
          --set image.tag=${env.TAG} \
          --set db.existingSecret=${params.DB_SECRET_NAME} \
          --set rabbitmq.existingSecret=${params.RMQ_SECRET_NAME} \
          --atomic \
          --timeout ${params.HELM_TIMEOUT}
    """
}

// Prove the rollout actually converged, then prove the app answers.
// helm --atomic already waits, so this is belt-and-braces plus a real HTTP check.
def verifyRollout() {
    sh """
        kubectl -n ${params.K8S_NAMESPACE} rollout status deploy/app01   --timeout=5m
        kubectl -n ${params.K8S_NAMESPACE} rollout status deploy/vproweb --timeout=5m
        kubectl -n ${params.K8S_NAMESPACE} rollout status statefulset/db01 --timeout=5m

        echo "--- deployed images ---"
        kubectl -n ${params.K8S_NAMESPACE} get deploy,statefulset \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\\t"}{.spec.template.spec.containers[0].image}{"\\n"}{end}'
    """
}

// End-to-end smoke test through the ALB. /login is used rather than / because
// Tomcat answers / with a 302 that a naive check reads as failure.
// Retried: freshly rolled pods take a moment to register as healthy targets.
def smokeTest() {
    def host = sh(returnStdout: true, script: """
        kubectl -n ${params.K8S_NAMESPACE} get ingress vprofile \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    """).trim()

    if (!host) {
        echo 'WARNING: no ALB hostname on the Ingress yet - skipping the smoke test'
        return
    }

    echo "smoke testing http://${host}/login"
    retry(6) {
        sh """
            sleep 10
            code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://${host}/login)
            echo "  GET /login -> \${code}"
            [ "\${code}" = "200" ]
        """
    }
    echo "APPLICATION IS LIVE: http://${host}/"
}

// -------- pipeline ----------------------------------------------------------

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        string(name: 'AWS_REGION', defaultValue: 'eu-west-3',
               description: 'AWS region of the ECR registry')
        string(name: 'IMAGE_TAG', defaultValue: '',
               description: 'Leave empty for <git-sha>-<build-number>, or set an explicit tag (e.g. v1.0.3). ECR repos are IMMUTABLE, so the tag must be unique per push')
        string(name: 'GATE_SEVERITY', defaultValue: 'HIGH,CRITICAL',
               description: 'Trivy severities that fail the build (fixable only, --ignore-unfixed)')
        string(name: 'TRIVY_CACHE_DIR', defaultValue: '/var/lib/jenkins/.cache/trivy',
               description: 'Persistent Trivy cache dir (must be writable by the jenkins user)')
        string(name: 'SONAR_CACHE_DIR', defaultValue: '/var/lib/jenkins/.sonar',
               description: 'Persistent SonarQube scanner cache dir, mounted as SONAR_USER_HOME (must be writable by the jenkins user)')
        string(name: 'SONAR_HOST_URL', defaultValue: 'http://localhost:9000',
               description: 'SonarQube base URL — runs as a container on this same instance')
        string(name: 'SONAR_PROJECT_KEY', defaultValue: 'vprofile',
               description: 'SonarQube project key (auto-created on first analysis)')
        string(name: 'MAVEN_HEAP', defaultValue: '-Xmx1g',
               description: 'Heap cap for the Maven JVM inside the app image build. Keep this bounded — SonarQube shares the 8 GB on this box')
        booleanParam(name: 'RUN_SONAR', defaultValue: true,
               description: 'Run Maven verify + SonarQube analysis')
        booleanParam(name: 'SONAR_GATE', defaultValue: true,
               description: 'ENFORCED: a failing quality gate stops the build before any image is built. Set false to drop back to audit mode - publish the verdict, do not act on it')
        booleanParam(name: 'SKIP_TESTS', defaultValue: false,
               description: 'Skip unit tests during Maven verify. Leaves SonarQube with no coverage data — only for debugging the pipeline')
        booleanParam(name: 'SECURITY_GATE', defaultValue: true,
               description: 'ENFORCED: fixable GATE_SEVERITY findings fail the build BEFORE ECR login, so a vulnerable image never reaches the registry. Accepted risks belong in Build-Images/.trivyignore, not in a lowered GATE_SEVERITY')
        booleanParam(name: 'PUSH_LATEST', defaultValue: false,
               description: 'Push a mutable "latest" tag. MUST stay false — the ECR repos are IMMUTABLE (see terraform)')
        booleanParam(name: 'DEPLOY', defaultValue: true,
               description: 'Deploy the freshly pushed tag to EKS with Helm. Turn off to build and publish only')
        string(name: 'CLUSTER_NAME', defaultValue: 'vprofile-eks',
               description: 'EKS cluster to deploy into')
        string(name: 'K8S_NAMESPACE', defaultValue: 'vprofile',
               description: 'Target namespace')
        string(name: 'HELM_RELEASE', defaultValue: 'vprofile',
               description: 'Helm release name. Changing this creates a SECOND parallel deployment, it does not rename the existing one')
        string(name: 'DB_SECRET_NAME', defaultValue: 'db01-credentials',
               description: 'Pre-existing Secret holding MYSQL_ROOT_PASSWORD. Created out of band so no credential ever enters the pipeline, the chart or Git')
        string(name: 'RMQ_SECRET_NAME', defaultValue: 'rmq01-credentials',
               description: 'Pre-existing Secret holding RABBITMQ_DEFAULT_USER and RABBITMQ_DEFAULT_PASS. Same contract as the database one - created out of band, never in the pipeline or Git')
        string(name: 'HELM_TIMEOUT', defaultValue: '10m',
               description: 'How long Helm waits for every workload to become Ready before rolling back')
        booleanParam(name: 'PARALLEL', defaultValue: false,
               description: 'Build/scan images in parallel. Risky while SonarQube shares this box — only enable on a larger agent')
    }

    environment {
        AWS_REGION       = "${params.AWS_REGION}"
        TRIVY_CACHE_DIR  = "${params.TRIVY_CACHE_DIR}"
        TRIVY_IGNOREFILE = "${WORKSPACE}/Build-Images/.trivyignore"
        MAVEN_CACHE      = '/var/lib/jenkins/.m2'
        SONAR_CACHE      = "${params.SONAR_CACHE_DIR}"
        SONAR_HOST_URL   = "${params.SONAR_HOST_URL}"
        REPO_URL         = 'https://github.com/yousefsalemW/DEVSECOPS-PLATFORM-EKS'
        // Build-scoped kubeconfig. Deliberately NOT ~/.kube/config: the pipeline
        // must not depend on, or disturb, whatever an operator set up by hand.
        KUBECONFIG       = "${WORKSPACE}/.kube/config"
    }

    stages {

        stage('Init') {
            steps {
                script {
                    // The ECR repos are IMMUTABLE, so the default tag has to be
                    // unique per build — a bare git sha would make any re-run of
                    // the same commit fail on ImageTagAlreadyExistsException.
                    env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse --short=8 HEAD').trim()
                    env.BUILD_DATE = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
                    env.TAG        = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim()
                                                             : "${env.GIT_SHA}-${env.BUILD_NUMBER}"

                    // Resolve the account id at runtime → build the ECR registry URL.
                    env.AWS_ACCOUNT_ID = sh(returnStdout: true,
                        script: 'aws sts get-caller-identity --query Account --output text').trim()
                    env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"

                    // Pre-warm the Trivy DBs ONCE so per-image scans use --skip-db-update.
                    sh "mkdir -p ${env.TRIVY_CACHE_DIR}"
                    retry(3) { sh "trivy image --cache-dir ${env.TRIVY_CACHE_DIR} --download-db-only" }
                    retry(3) { sh "trivy image --cache-dir ${env.TRIVY_CACHE_DIR} --download-java-db-only" }

                    echo """
                    ┌────────────────────────────────────────────
                    │ REGISTRY   : ${env.ECR_REGISTRY}
                    │ TAG        : ${env.TAG}   (git ${env.GIT_SHA})
                    │ SONAR      : ${params.RUN_SONAR ? env.SONAR_HOST_URL : 'skipped'}
                    │ SONAR GATE : ${params.SONAR_GATE ? 'enforced' : 'audit only'}
                    │ TRIVY GATE : ${params.SECURITY_GATE ? params.GATE_SEVERITY : 'audit only'}
                    │ PARALLEL   : ${params.PARALLEL}
                    │ IMAGES     : ${IMAGES.collect { it.name }.join(', ')}
                    └────────────────────────────────────────────"""
                }
            }
        }

        // ---------- 1. Compile + test on the host so Sonar has bytecode --------
        stage('Maven Verify') {
            when { expression { params.RUN_SONAR } }
            steps { script { mavenVerify() } }
            post {
                always {
                    junit testResults: 'Build-Images/target/surefire-reports/*.xml',
                          allowEmptyResults: true
                }
            }
        }

        // ---------- 2. SonarQube analysis + quality gate -----------------------
        stage('SonarQube') {
            when { expression { params.RUN_SONAR } }
            steps {
                script {
                    sonarScan()
                    if (params.SONAR_GATE) {
                        sonarQualityGate()
                    } else {
                        echo 'SONAR_GATE=false → analysis published, verdict not enforced'
                        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                            sonarQualityGate()
                        }
                    }
                }
            }
        }

        // ---------- 3. Build every image (with --pull, BuildKit, OCI labels) ---
        stage('Build') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> buildImage(img) } } }
        }

        // ---------- 4. Security scan with Trivy + SBOM -------------------------
        stage('Trivy Scan') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> scanImage(img) } } }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-*.txt, sbom-*.cdx.json', allowEmptyArchive: true
                }
            }
        }

        // ---------- 5. Login to ECR --------------------------------------------
        stage('ECR Login') {
            steps {
                retry(3) {
                    sh '''
                        aws ecr get-login-password --region ${AWS_REGION} \
                          | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    '''
                }
            }
        }

        // ---------- 6. Tag images ----------------------------------------------
        stage('Tag') {
            steps { script { IMAGES.each { img -> tagImage(img) } } }
        }

        // ---------- 7. Push to ECR (with retry) --------------------------------
        stage('Push') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> pushImage(img) } } }
        }

        // ---------- 8. Verify images exist in ECR ------------------------------
        stage('Verify') {
            steps { script { IMAGES.each { img -> verifyImage(img) } } }
        }

        // ---------- 9. Deploy to EKS -------------------------------------------
        // Runs only after every image is built, scanned and confirmed present in
        // ECR, so the tag deployed here is provably the tag that passed the gates.
        stage('Deploy') {
            when { expression { params.DEPLOY } }
            steps {
                script {
                    preflight()
                    renderManifests()
                    deployRelease()
                    verifyRollout()
                    smokeTest()
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: "rendered-*.yaml", allowEmptyArchive: true
                }
                failure {
                    script {
                        echo '--- deploy failed: helm --atomic has rolled the release back ---'
                        sh """
                            helm -n ${params.K8S_NAMESPACE} history ${params.HELM_RELEASE} || true
                            kubectl -n ${params.K8S_NAMESPACE} get pods || true
                            kubectl -n ${params.K8S_NAMESPACE} get events \
                              --sort-by=.lastTimestamp | tail -30 || true
                        """
                    }
                }
            }
        }
    }

    // ---------- Cleanup — remove local images after push -----------------------
    // In post{always} so it runs even if a stage fails.
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
                // Trim OLD build cache but keep recent layers (BuildKit stays useful).
                sh 'docker builder prune -f --keep-storage 10GB || true'
                sh 'docker logout ${ECR_REGISTRY} || true'
            }
        }
        success { echo "All images pushed to ${env.ECR_REGISTRY} with tag ${env.TAG}" }
        failure { echo "Pipeline failed — check the Trivy artifacts and the console log" }
    }
}
