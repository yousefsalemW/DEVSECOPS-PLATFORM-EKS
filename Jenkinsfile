// =============================================================================
//  VProfile-Final — ECR Build/Scan/Push Pipeline
//  ALnaqib · DevOps Engineer
//
//  Stages:  Init → Build → Trivy Scan (+ SBOM) → ECR Login → Tag → Push
//           → Verify → Cleanup
//
//  Requirements on the Jenkins node:
//    - docker with BuildKit (jenkins user in the docker group)
//    - trivy
//    - aws cli v2
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
// NOTE: parallel build on a small agent (t3.medium = 2 vCPU / 4 GB) can OOM,
// especially the Maven app image. Keep PARALLEL=false unless the agent is bigger.
def forEachImage(List images, boolean parallelMode, Closure body) {
    if (parallelMode) {
        parallel images.collectEntries { img -> ["${img.name}", { body(img) }] }
    } else {
        images.each { body(it) }
    }
}

def buildImage(img) {
    echo "==> build ${img.name}:${env.TAG}"
    // --pull        : always fetch the latest base image (covers base-image CVEs)
    // BuildKit      : faster builds + better layer cache
    // OCI labels    : git sha / build date / version for audit & traceability
    sh """
        DOCKER_BUILDKIT=1 docker build --pull \
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
    sh """
        trivy image --cache-dir ${env.TRIVY_CACHE_DIR} \
          --no-progress --ignore-unfixed --skip-db-update \
          --severity HIGH,CRITICAL --format table \
          --output trivy-${img.name}.txt ${ref}
    """

    // (b) SBOM in CycloneDX format — archived per image.
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

// -------- pipeline ----------------------------------------------------------

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        string(name: 'AWS_REGION', defaultValue: 'eu-west-3',
               description: 'AWS region of the ECR registry')
        string(name: 'IMAGE_TAG', defaultValue: '',
               description: 'Leave empty to use the short git SHA, or set an immutable tag (e.g. v1.0.3)')
        string(name: 'GATE_SEVERITY', defaultValue: 'HIGH,CRITICAL',
               description: 'Trivy severities that fail the build (fixable only, --ignore-unfixed)')
        string(name: 'TRIVY_CACHE_DIR', defaultValue: '/var/lib/jenkins/.cache/trivy',
               description: 'Persistent Trivy cache dir (must be writable by the jenkins user)')
        booleanParam(name: 'SECURITY_GATE', defaultValue: false,
               description: 'Audit mode when false: scan + SBOM still run and are archived, but findings never block the push. Set true to fail the build on GATE_SEVERITY findings')
        booleanParam(name: 'PUSH_LATEST', defaultValue: false,
               description: 'Push a mutable "latest" tag. Keep false for IMMUTABLE prod repos (see terraform)')
        booleanParam(name: 'PARALLEL', defaultValue: false,
               description: 'Build/scan images in parallel. Risky on a t3.medium — only enable on a larger agent')
    }

    environment {
        AWS_REGION      = "${params.AWS_REGION}"
        TRIVY_CACHE_DIR = "${params.TRIVY_CACHE_DIR}"
        REPO_URL        = 'https://github.com/yousefsalemW/VProfile-Final'
    }

    stages {

        stage('Init') {
            steps {
                script {
                    // Immutable git sha for labels; the push TAG may be a semver override.
                    env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse --short=8 HEAD').trim()
                    env.BUILD_DATE = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
                    env.TAG        = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim() : env.GIT_SHA

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
                    │ REGISTRY : ${env.ECR_REGISTRY}
                    │ TAG      : ${env.TAG}   (git ${env.GIT_SHA})
                    │ GATE     : ${params.SECURITY_GATE ? params.GATE_SEVERITY : 'disabled'}
                    │ PARALLEL : ${params.PARALLEL}
                    │ IMAGES   : ${IMAGES.collect { it.name }.join(', ')}
                    └────────────────────────────────────────────"""
                }
            }
        }

        // ---------- 1. Build every image (with --pull, BuildKit, OCI labels) ---
        stage('Build') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> buildImage(img) } } }
        }

        // ---------- 2. Security scan with Trivy + SBOM -------------------------
        stage('Trivy Scan') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> scanImage(img) } } }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-*.txt, sbom-*.cdx.json', allowEmptyArchive: true
                }
            }
        }

        // ---------- 3. Login to ECR --------------------------------------------
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

        // ---------- 4. Tag images ----------------------------------------------
        stage('Tag') {
            steps { script { IMAGES.each { img -> tagImage(img) } } }
        }

        // ---------- 5. Push to ECR (with retry) --------------------------------
        stage('Push') {
            steps { script { forEachImage(IMAGES, params.PARALLEL) { img -> pushImage(img) } } }
        }

        // ---------- 6. Verify images exist in ECR ------------------------------
        stage('Verify') {
            steps { script { IMAGES.each { img -> verifyImage(img) } } }
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
