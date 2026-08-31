# Patch Application Guide

**Generated:** 2026-08-30
**Patches:** 4 — one per repository. **They are not interchangeable and must not be combined.**

Every patch was generated with `git diff` against a fresh clone of the repository at HEAD, then **verified by applying it to a second, pristine clone**. All four passed `git apply --check` and `git apply`.

| Repository | HEAD when generated | Patch file | Files changed |
|---|---|---|---|
| `DEVSECOPS-PLATFORM-EKS` | `9d0c5c0` | `DEVSECOPS_PLATFORM_EKS_FIX.patch` | 2 |
| `Vprofile-Secured-Orchestrator` | `ed67139` | `VPROFILE_ORCHESTRATOR_FIX.patch` | 6 (1 new, 1 deleted) |
| `Vprofile-terraform-on-aws-` | HEAD | `VPROFILE_TERRAFORM_FIX.patch` | 1 |
| `containerization-with-Ansible` | HEAD | `ANSIBLE_CONTAINERIZATION_FIX.patch` | 6 (2 new) |

> ⚠️ **These are four separate Git repositories.** A patch applied from the wrong repository root will fail `git apply --check`. That failure is the safety net working — do not use `--3way` or `-p0` to force it.

---

## Pre-apply — do this once per repository

```bash
cd /path/to/<repository>

# 1. Confirm you are in the right repository
git remote -v

# 2. Confirm a clean tree — the patch assumes no local modifications
git status

# 3. Confirm you are at the HEAD the patch was built against
git log --oneline -1

# 4. Create a rollback point
git checkout -b credibility-repair
```

Working on a branch is the rollback mechanism. If anything goes wrong:

```bash
git checkout .                 # discard unstaged changes
git checkout main              # leave the branch
git branch -D credibility-repair
```

If your HEAD has moved since generation, `git apply --check` will tell you before anything changes. In that case re-generate rather than forcing.

---

# 1 · DEVSECOPS-PLATFORM-EKS

**Repository** → `DEVSECOPS-PLATFORM-EKS`
**Patch file** → `DEVSECOPS_PLATFORM_EKS_FIX.patch`

**What it changes**
- `Jenkinsfile` — `scanImage()` gate block: adds `--exit-code 2`, captures the status with `returnStatus: true`, and fails the build with distinct messages for a policy violation (exit 2) versus a scanner failure (exit 1).
- `README.md` — supply-chain row and the pipeline stage list now describe a gate rather than a scan.

**Not changed:** report call (a) and SBOM call (b) remain non-blocking; `--ignore-unfixed` and `--ignorefile` are untouched; the `SECURITY_GATE=false` audit-mode escape hatch is preserved.

### Apply

```bash
cd /path/to/DEVSECOPS-PLATFORM-EKS
git status
git apply --check DEVSECOPS_PLATFORM_EKS_FIX.patch
git apply DEVSECOPS_PLATFORM_EKS_FIX.patch
```

### Validation

```bash
# Static
grep -n 'exit-code 2' Jenkinsfile                       # expect 1 match
grep -n 'SECURITY GATE FAILED' Jenkinsfile              # expect 1 match
grep -n 'Trivy gate before ECR login' README.md         # expect 1 match
python3 -c "s=open('Jenkinsfile').read(); assert s.count('{')==s.count('}'); print('braces balanced')"

# Groovy compiles (from the Jenkins controller)
java -jar jenkins-cli.jar -s http://localhost:8080 declarative-linter < Jenkinsfile
```
**Expected:** `Jenkinsfile successfully validated.`

```bash
# Prove the exit-code contract itself
trivy image --no-progress --ignore-unfixed --exit-code 2 \
  --severity HIGH,CRITICAL vulnerables/web-dvwa:latest ; echo "exit=$?"
```
**Expected:** `exit=2`

### ⚠️ The decisive runtime test

```bash
# Temporarily pin an old base in ONE image, e.g. Build-Images/images/memcached/Dockerfile:
#   FROM memcached:1.6.9
# Then run the pipeline with SECURITY_GATE=true
```
**Expected:**
- `Trivy Scan` stage **FAILS** with `SECURITY GATE FAILED for vprofile-mc:<tag>`
- `ECR Login`, `Tag`, `Push`, `Verify`, `Deploy` **do not execute**
- `trivy-*.txt` and `sbom-*.cdx.json` **are still archived** (the `post { always }` block)
- `aws ecr describe-images --repository-name vprofile-mc` shows **no new tag**

Then re-run with `SECURITY_GATE=false` — **expected:** pipeline completes, findings printed, no failure. Revert the temporary pin afterwards.

### ⚠️ Expect the first real build to fail

That is the fix working, not a regression. `.trivyignore` currently accepts 2 CVEs; anything else fixable at HIGH/CRITICAL across the 5 images will now stop the build. Triage from the archived `trivy-*.txt`, then either bump the dependency or add a **documented** entry to `Build-Images/.trivyignore`. Do not lower `GATE_SEVERITY`.

### Rebuild / redeploy

None required by the patch itself. The next pipeline run exercises the new gate.

---

# 2 · Vprofile-Secured-Orchestrator

**Repository** → `Vprofile-Secured-Orchestrator`
**Patch file** → `VPROFILE_ORCHESTRATOR_FIX.patch`

**This is the largest and only security-relevant patch.**

**What it changes**
- `build-and-push.sh` — removes `|| true`, adds `--exit-code 2`, scans all four images before deciding, aborts before `docker login` if any fails. `GATE=0` gives audit mode.
- `images/app/Dockerfile` — **removes `DB_USER`, `DB_PASS`, `RMQ_USER`, `RMQ_PASS` build args entirely.** Writes Spring placeholders instead, and adds two build-time `grep -q` assertions that fail the build if a literal credential is ever written again. Hostname args (`DB_HOST`, `MC_HOST`, `RMQ_HOST`) are kept — topology, not secrets.
- `k8s/05-app.yaml` — adds four `secretKeyRef` env entries from the existing `app-secret`; image bumped to `:1.1`.
- `k8s/01-secret.yaml` → **deleted**, replaced by `k8s/01-secret.example.yaml` with `REPLACE_ME` placeholders and the `kubectl create secret` command.
- `deploy.sh` — no longer applies a committed Secret; fails fast with the create command if `app-secret` is absent.
- `README.md` — corrects "Credential-free images" and "stops the push", plus the repository layout and the credential note.

### Apply

```bash
cd /path/to/Vprofile-Secured-Orchestrator
git status
git apply --check VPROFILE_ORCHESTRATOR_FIX.patch
git apply VPROFILE_ORCHESTRATOR_FIX.patch
git status      # expect: 1 deleted, 1 untracked (01-secret.example.yaml), 4 modified
```

### Validation — static

```bash
shellcheck build-and-push.sh deploy.sh                    # expect no output
bash -n build-and-push.sh && bash -n deploy.sh

# No credential literals survive anywhere
grep -rn 'admin123\|ChangeMe_Root' . --exclude-dir=.git   # expect NO output
grep -cE 'DB_PASS|RMQ_PASS' images/app/Dockerfile         # expect 0

# Manifests parse
python3 -c "import yaml;[list(yaml.safe_load_all(open(f))) for f in ['k8s/05-app.yaml','k8s/01-secret.example.yaml']];print('YAML OK')"
```

### Validation — the image is genuinely credential-free

```bash
docker build --platform linux/amd64 -t vprofile-app:test -f images/app/Dockerfile src/
```
The build log must show the four placeholder lines. The two `grep -q` assertions **fail the build** if a literal value is ever substituted.

```bash
# 1. The properties file inside the WAR carries placeholders, not values
docker run --rm --entrypoint sh vprofile-app:test -c \
  'cd /tmp && mkdir -p x && cd x && jar xf /usr/local/tomcat/webapps/ROOT.war \
   WEB-INF/classes/application.properties && cat WEB-INF/classes/application.properties' \
  | grep -E '^(jdbc|rabbitmq)\.(username|password)='
```
**Expected exactly:**
```
jdbc.username=${JDBC_USERNAME}
jdbc.password=${JDBC_PASSWORD}
rabbitmq.username=${RABBITMQ_USERNAME}
rabbitmq.password=${RABBITMQ_PASSWORD}
```

```bash
# 2. Nothing leaked into layer history or the image bytes
docker history --no-trunc vprofile-app:test | grep -Ei 'admin123|DB_PASS|RMQ_PASS' \
  && echo "FAIL" || echo "PASS: clean history"
docker save vprofile-app:test | strings | grep -c 'admin123'    # expect 0
```

### Validation — the scan gate actually stops the push

```bash
# Temporarily pin an old base in images/memcached/Dockerfile, e.g. FROM memcached:1.6.9
./build-and-push.sh ; echo "exit=$?"
```
**Expected:** `SECURITY GATE FAILED - no images pushed.`, `exit=2`, and **`docker login` is never reached**.

```bash
GATE=0 ./build-and-push.sh      # audit mode: warning printed, push proceeds
```
Revert the temporary pin afterwards.

### Validation — the decisive runtime test

```bash
kubectl -n vprofile create secret generic app-secret \
  --from-literal=db-root-password="$(openssl rand -base64 24)" \
  --from-literal=db-user=vprofile \
  --from-literal=db-password="$(openssl rand -base64 24)" \
  --from-literal=rmq-user=vprofile \
  --from-literal=rmq-password="$(openssl rand -base64 24)"

kubectl -n vprofile apply -f k8s/05-app.yaml
kubectl -n vprofile rollout status deploy/vpro-app --timeout=180s
kubectl -n vprofile logs deploy/vpro-app | grep -i "access denied" \
  && echo "FAIL: placeholder did not resolve" || echo "PASS: DB auth succeeded"

# Now break the password in the SECRET ONLY — do not rebuild the image
kubectl -n vprofile patch secret app-secret -p '{"stringData":{"db-password":"WrongOnPurpose"}}'
kubectl -n vprofile rollout restart deploy/vpro-app
kubectl -n vprofile logs deploy/vpro-app | grep -i "access denied"
```
**Expected:** `Access denied` **now appears**.

> **This is the test that proves the claim.** If the app still connects after the Secret is wrong, the credential is still baked into the image and the README claim is still false. Restore the correct password afterwards.

### Rebuild / redeploy — REQUIRED

```bash
TAG=1.1 ./build-and-push.sh
kubectl -n vprofile apply -f k8s/05-app.yaml
```

### 🔴 Security cleanup — published images still contain credentials

**Fixing the Dockerfile does not retroactively fix an image already on Docker Hub.** `alnaqib/vprofile-app:1.0` still has `admin123` and `guest` compiled into the WAR, and it is public.

1. Push the fixed image as `:1.1` (above).
2. **Delete the `1.0` tag** — hub.docker.com → `alnaqib/vprofile-app` → Tags → `1.0` → Delete.
3. Confirm: `docker pull alnaqib/vprofile-app:1.0` should fail.

**Rotation:** `admin123` and `guest` are the upstream VProfile demo defaults, not real credentials, so **no production rotation is required**. If you ever reused either string anywhere else, rotate it there. The reason to remove the image is that the repository asserted a security property it did not have — not that a real secret leaked.

**Git history:** the credentials remain in history (`images/app/Dockerfile`, `k8s/01-secret.yaml`). Because they are public demo defaults, **history rewriting is not warranted** — the cost of a force-push outweighs the benefit. Leave history alone.

---

# 3 · Vprofile-terraform-on-aws-

**Repository** → `Vprofile-terraform-on-aws-`
**Patch file** → `VPROFILE_TERRAFORM_FIX.patch`

**Documentation only. Zero `.tf` files are touched — by design.**

**What it changes** — `README.md` only:
- Stack table: `IAM roles and instance profiles` → security groups chained by group reference, no public IPs. **The replacement claim is verifiable in `09/10/11/12-sg-*.tf`.**
- Security bullet: replaced with an explicit statement that no IAM roles or instance profiles are created, and why none are needed.
- "Not yet implemented": adds an IAM entry (with the SSM Session Manager path as the correct future fix) and a remote-state entry.

**No fake IAM resources. No fake modules.** The earlier audit note claiming a "Reusable Terraform Modules" README claim was **stale** — the word "module" does not appear in this README, so there was nothing to remove.

### Apply

```bash
cd /path/to/Vprofile-terraform-on-aws-
git status
git apply --check VPROFILE_TERRAFORM_FIX.patch
git apply VPROFILE_TERRAFORM_FIX.patch
```

### Validation

```bash
# The false claim is gone
grep -n "IAM roles and instance profiles rather than" README.md    # expect NO output
grep -n "No IAM roles or instance profiles are created" README.md  # expect 1 match

# The README now matches the code
grep -rn 'aws_iam' vprofile-micro/*.tf              || echo "zero aws_iam_* — matches README"
grep -rn 'iam_instance_profile' vprofile-micro/*.tf || echo "zero instance profiles — matches README"
grep -c '^module ' vprofile-micro/*.tf | grep -v ':0' || echo "zero modules — no fake modules added"

# The claim that was KEPT is real
grep -n 'source_security_group_id\|security_groups' \
  vprofile-micro/09-sg-app.tf vprofile-micro/10-sg-rds.tf \
  vprofile-micro/11-sg-cache.tf vprofile-micro/12-sg-mq.tf

# Code is unchanged and still valid
git diff --stat            # expect: README.md only
cd vprofile-micro && terraform init -backend=false && terraform validate
```
**Expected:** `Success! The configuration is valid.`

### Rebuild / redeploy

None. No infrastructure change. No `terraform apply` needed.

---

# 4 · containerization-with-Ansible

**Repository** → `containerization-with-Ansible`
**Patch file** → `ANSIBLE_CONTAINERIZATION_FIX.patch`

**What it changes**
- **New** `inventory.example.ini` — RFC 5737 documentation addresses (`192.0.2.x`, unroutable), `REPLACE_ME` for user and key path, **no password field**.
- **New** `ansible.cfg` — inventory path, roles path, become defaults, and `host_key_checking = False` **with the reason written next to it**.
- `.gitignore` — ignores real inventories (`inventory.ini`, `hosts`, …), vault files; comments translated to English.
- `Jenkinsfile` — adds an `INVENTORY` build parameter, a `Preflight` stage that pings the fleet first, `-i` on both playbook calls, and changes `Verification` from `docker ps` **on the agent** to `ansible … production -a 'docker ps'` **across the managed hosts**.
- `roles/webapp/tasks/main.yml` — four Arabic comments and the user-facing `debug` message translated to English.
- `README.md` — inventory section, repository layout, run commands, verification, and two Known Limitations corrected.

> One of those corrections fixes a limitation that was **wrong in the safe direction**: the README claimed the image tag was "fixed in the role", but `webapp_image` is a role default and *is* overridable. The docs understated the code.

### Apply

```bash
cd /path/to/containerization-with-Ansible
git status
git apply --check ANSIBLE_CONTAINERIZATION_FIX.patch
git apply ANSIBLE_CONTAINERIZATION_FIX.patch
git status      # expect 4 modified, 2 untracked (ansible.cfg, inventory.example.ini)
git add ansible.cfg inventory.example.ini
```

### Validation — no secrets, reproducible clone

```bash
# No real addresses or credentials
grep -c '192\.0\.2\.' inventory.example.ini                  # expect 3 (RFC 5737)
grep -E '^[^#]*ansible_password *=' inventory.example.ini    # expect NO output
grep -n 'inventory.ini' .gitignore                           # expect a match

# Clean-clone reproducibility
cp inventory.example.ini inventory.ini
# edit inventory.ini with real values, then:
ansible production -m ping        # no -i needed; ansible.cfg supplies it
```
**Expected:** `SUCCESS` per host.

```bash
# Syntax and lint
ansible-playbook --syntax-check install-docker.yml deploy-webapp.yml
ansible-lint install-docker.yml deploy-webapp.yml roles/

# Dry run
ansible-playbook install-docker.yml --check --diff

# Prove the corrected limitation: the image tag IS overridable
ansible-playbook deploy-webapp.yml -e webapp_image=alnaqib/efe-egy-web:1.0 --check --diff
```
**Expected:** the diff shows the overridden tag.

```bash
# No Arabic left in code
python3 -c "
import os,re
ar=re.compile(r'[؀-ۿ]'); h=[]
for root,dirs,files in os.walk('.'):
    dirs[:]=[d for d in dirs if d!='.git']
    for f in files:
        p=os.path.join(root,f)
        try: t=open(p,encoding='utf-8',errors='ignore').read()
        except: continue
        if ar.search(t): h.append(p)
print('clean' if not h else h)"

# Jenkinsfile
grep -c "ansible-playbook -i" Jenkinsfile     # expect 2
python3 -c "s=open('Jenkinsfile').read(); assert s.count('{')==s.count('}'); print('braces balanced')"
```

### Jenkins setup — required before the next build

The pipeline now expects a real inventory **on the agent**, not in the repository:

```bash
# On the Jenkins agent
sudo mkdir -p /etc/ansible
sudo cp inventory.example.ini /etc/ansible/inventory.ini
sudo vi /etc/ansible/inventory.ini        # real addresses, user, key path
sudo chown jenkins:jenkins /etc/ansible/inventory.ini
sudo chmod 600 /etc/ansible/inventory.ini
```

Override per build with the `INVENTORY` parameter if the path differs. If the file is missing, the `Preflight` stage fails in seconds with the exact instruction — instead of failing mid-deployment across a partial fleet.

### Rebuild / redeploy

None. Next Jenkins build exercises the new stages.

---

# Apply everything — copy-paste sequence

Documentation-only patches first (zero risk), the security patch last.

```bash
# 3 — Terraform (docs only)
cd /path/to/Vprofile-terraform-on-aws-
git checkout -b credibility-repair
git apply --check VPROFILE_TERRAFORM_FIX.patch && git apply VPROFILE_TERRAFORM_FIX.patch

# 4 — Ansible
cd /path/to/containerization-with-Ansible
git checkout -b credibility-repair
git apply --check ANSIBLE_CONTAINERIZATION_FIX.patch && git apply ANSIBLE_CONTAINERIZATION_FIX.patch
git add ansible.cfg inventory.example.ini

# 1 — EKS  (validate the gate BEFORE committing the README change)
cd /path/to/DEVSECOPS-PLATFORM-EKS
git checkout -b credibility-repair
git apply --check DEVSECOPS_PLATFORM_EKS_FIX.patch && git apply DEVSECOPS_PLATFORM_EKS_FIX.patch

# 2 — Orchestrator  (validate credentials + gate BEFORE pushing :1.1)
cd /path/to/Vprofile-Secured-Orchestrator
git checkout -b credibility-repair
git apply --check VPROFILE_ORCHESTRATOR_FIX.patch && git apply VPROFILE_ORCHESTRATOR_FIX.patch
git add k8s/01-secret.example.yaml
```

Suggested commit messages:

```
EKS           fix: make the Trivy security gate actually fail the build

              The gate call omitted --exit-code, so trivy exited 0 regardless of
              findings while the SECURITY_GATE parameter described it as ENFORCED.
              Adds --exit-code 2 and distinguishes a policy violation from a
              scanner failure. README updated to match the implementation.

Orchestrator  fix: enforce the scan gate and remove credentials from the app image

              build-and-push.sh discarded trivy's exit status with '|| true' and
              trivy defaults to --exit-code 0, so no finding could ever stop a push.
              The app Dockerfile also compiled credentials into the WAR via build
              args, so the published image was not credential-free as documented.
              Credentials now resolve from the existing Secret at runtime.

Terraform     docs: remove IAM claims the configuration does not implement

              The README claimed IAM roles and instance profiles; there are zero
              aws_iam_* resources. Replaced with the security-group chaining that
              is actually implemented, and recorded IAM under Not yet implemented.

Ansible       fix: make the repository and pipeline reproducible

              Adds an example inventory and ansible.cfg, passes -i explicitly in
              Jenkins, and verifies across the managed hosts rather than on the
              agent. Corrects a limitation that understated the code and
              translates remaining Arabic comments.
```

---

# Post-apply checklist

**☐ 1.** All four `git apply --check` pass before any `git apply`
**☐ 2.** EKS — Groovy lints; `--exit-code 2` present; braces balanced
**☐ 3.** EKS — pipeline **fails** with a deliberately vulnerable image, and `ECR Login` never runs
**☐ 4.** EKS — `SECURITY_GATE=false` still completes
**☐ 5.** Orchestrator — shellcheck clean on both scripts
**☐ 6.** Orchestrator — WAR contains **placeholders only**, no `admin123`
**☐ 7.** Orchestrator — `docker history` and `docker save | strings` are clean
**☐ 8.** Orchestrator — **wrong password in the Secret produces `Access denied`** ← the decisive test
**☐ 9.** Orchestrator — `./build-and-push.sh` exits 2 and never reaches `docker login`
**☐ 10.** Orchestrator — `:1.1` pushed, **`:1.0` deleted from Docker Hub**
**☐ 11.** Terraform — `git diff --stat` shows README.md only; `terraform validate` succeeds
**☐ 12.** Ansible — clean-clone `ansible production -m ping` succeeds
**☐ 13.** Ansible — real inventory placed on the Jenkins agent
**☐ 14.** Ansible — no Arabic remains; `-i` present twice
**☐ 15.** No credential literal introduced by any patch *(verified at generation: zero)*

---

# Verification performed at generation time

Each patch was applied to a **second, pristine clone** and validated:

| Check | Result |
|---|---|
| `git apply --check` on a fresh clone, all 4 | ✅ PASSED |
| `git apply` on a fresh clone, all 4 | ✅ APPLIED |
| Credential literals introduced by any patch | ✅ **ZERO** |
| `shellcheck` — `build-and-push.sh`, `deploy.sh` | ✅ clean |
| `bash -n` — both scripts | ✅ valid |
| Groovy brace balance — EKS 270/270, Ansible 23/23 | ✅ balanced |
| YAML parse — `05-app.yaml`, `01-secret.example.yaml`, `webapp/tasks/main.yml` | ✅ valid |
| sed + assertion logic simulated on a real `application.properties` | ✅ placeholders only, **0** literals |
| `admin123` / `ChangeMe` anywhere in the patched Orchestrator | ✅ **0** |
| `\|\| true` live in `build-and-push.sh` | ✅ **0** (only in an explanatory comment) |
| Terraform `.tf` files touched | ✅ **0** — docs-only, as intended |
| Fake IAM resources or modules added | ✅ **0** |
| RFC 5737 documentation addresses in the example inventory | ✅ 3 |
| `ansible_password` assignment | ✅ **0** (only a comment forbidding it) |
| Arabic remaining in Ansible repo | ✅ **NONE** |

---

# Not included in these patches

Deliberately out of scope — these need judgement or account access, not a diff:

| Item | Why excluded |
|---|---|
| **Deleting `alnaqib/vprofile-app:1.0` from Docker Hub** | Registry action, not a repository change. **Still required** — see Repair 2 |
| **Arabic comments in `DEVSECOPS-PLATFORM-EKS`** (6 files, incl. `.trivyignore`) | Translating the CVE acceptance justifications changes the meaning of security decisions. You should write those, not me — but they are the most valuable ones to have in English, because they are the evidence that risk acceptance was deliberate |
| **LICENSE files** for 5 repositories | A licence choice is yours. Copy `Alnaqib-s-Journey/LICENSE` |
| **Branch protection / PR workflow** | GitHub settings, not files. **8 of 11 postings** in the market sample asked for collaboration and your repositories currently show none |
| **`k8s-ha-security-groups.html`** (Flannel + 2 workers vs the real Calico + 3) | Deleting a file you may still want is your call. Delete, or add a header stating it does not describe this build |
| **CV changes** | Untouched, as instructed. `BASE_CV_v2` remains a **DRAFT**; `BASE_CV_v1` remains **ACTIVE** |

---

# One thing to tell me afterwards

`BASE_CV_v2` currently says *"five container images with Trivy vulnerability scans and CycloneDX SBOMs"* — the enforcement wording was removed because the gate did not enforce.

**Once EKS checklist items 3 and 4 pass**, tell me, and I will restore the stronger, now-truthful claim:

> *"a Jenkins pipeline gated on code quality and image vulnerabilities"*
