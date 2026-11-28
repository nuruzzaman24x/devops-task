#!/usr/bin/env bash
# verify_assessment.sh
# Run this from the ROOT of your devops-task repo:
#   chmod +x verify_assessment.sh && ./verify_assessment.sh
#
# It checks presence of required files + (when the tool is installed)
# runs linters/validators, and prints a PASS/WARN/FAIL per requirement.
# It does NOT guarantee correctness of content, only that the required
# pieces exist and basic static checks succeed — read the WARN lines
# yourself before submitting.

set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "== $1 =="; }

have() { command -v "$1" >/dev/null 2>&1; }

f() { [ -f "$1" ]; }
d() { [ -d "$1" ]; }

# ---------------------------------------------------------------
section "Step 1: Application & Containerization"
# ---------------------------------------------------------------
if d app; then ok "app/ exists"; else bad "app/ directory missing"; fi

if f app/main.py || ls app/*.go app/*.js app/*.ts >/dev/null 2>&1; then
  ok "app source file found"
else
  bad "no app source file found under app/"
fi

if d tests && (f tests/test_main.py || ls tests/*test* >/dev/null 2>&1); then
  ok "unit tests present under tests/"
else
  bad "no unit tests found under tests/"
fi

if have pytest && f tests/test_main.py; then
  echo "  running pytest..."
  if (cd tests && pytest -q >/tmp/pytest.log 2>&1 || pytest -q tests >/tmp/pytest.log 2>&1); then
    ok "pytest run (check /tmp/pytest.log for details)"
  else
    warn "pytest run reported failures — check /tmp/pytest.log"
  fi
else
  warn "pytest not available/applicable — run tests manually"
fi

if f Dockerfile; then
  ok "Dockerfile exists"
  grep -qiE '^FROM .*( as |AS )' Dockerfile && ok "Dockerfile looks multi-stage" || warn "Dockerfile may not be multi-stage (no 'FROM ... AS ...')"
  grep -qE '^FROM [^ ]+:[^ ]+(@sha256:[a-f0-9]+)?[[:space:]]*(AS|as)?' Dockerfile && ok "base image appears pinned to a tag/digest" || warn "confirm base image is pinned (not ':latest')"
  grep -qiE 'FROM .*:latest' Dockerfile && bad "Dockerfile uses ':latest' tag somewhere"
  grep -qiE '^USER ' Dockerfile && ok "Dockerfile sets a USER (check it's non-root, not 'USER root')" || bad "Dockerfile has no USER instruction (likely runs as root)"
  grep -qiE 'HEALTHCHECK' Dockerfile && ok "HEALTHCHECK present" || bad "HEALTHCHECK missing"
  grep -qiE 'LABEL org\.opencontainers\.image' Dockerfile && ok "OCI labels present" || warn "no org.opencontainers.image labels found"
else
  bad "Dockerfile missing"
fi

if f .dockerignore; then ok ".dockerignore exists"; else bad ".dockerignore missing"; fi

if f docker-compose.yml; then
  ok "docker-compose.yml exists"
  grep -qi '8080' docker-compose.yml && ok "port 8080 referenced" || warn "port 8080 not found in docker-compose.yml"
  grep -qi 'healthcheck' docker-compose.yml && ok "healthcheck defined" || bad "no healthcheck in docker-compose.yml"
  grep -qi 'restart' docker-compose.yml && ok "restart policy defined" || bad "no restart policy in docker-compose.yml"
  grep -qiE 'mem_limit|cpus|deploy:' docker-compose.yml && ok "resource limits appear defined" || bad "no resource limits found in docker-compose.yml"
else
  bad "docker-compose.yml missing"
fi

if have hadolint && f Dockerfile; then
  echo "  running hadolint..."
  hadolint Dockerfile || warn "hadolint reported issues (see above)"
else
  warn "hadolint not installed — install it to lint the Dockerfile (or check CI output)"
fi

# ---------------------------------------------------------------
section "Step 2: CI/CD Pipeline (GitHub Actions)"
# ---------------------------------------------------------------
if d .github/workflows; then
  ok ".github/workflows/ exists"
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    echo "  -- $wf --"
    grep -qiE 'lint|flake8|ruff|eslint' "$wf" && ok "    lint step found" || warn "    no lint step found"
    grep -qiE 'pytest|test' "$wf" && ok "    test step found" || warn "    no test step found"
    grep -qiE 'coverage' "$wf" && ok "    coverage reporting found" || warn "    no coverage step found"
    grep -qiE 'hadolint' "$wf" && ok "    hadolint step found" || warn "    no hadolint step found"
    grep -qiE 'shellcheck' "$wf" && ok "    shellcheck step found" || warn "    no shellcheck step found"
    grep -qiE 'trivy' "$wf" && ok "    trivy scan step found" || warn "    no trivy step found"
    grep -qiE 'severity.*CRITICAL|exit-code' "$wf" && ok "    trivy appears configured to fail on CRITICAL" || warn "    confirm trivy fails the build on CRITICAL vulns"
    grep -qiE 'platforms:.*linux/amd64.*linux/arm64|linux/arm64.*linux/amd64' "$wf" && ok "    multi-arch build (amd64+arm64) found" || warn "    multi-arch build not clearly configured"
    grep -qiE 'cache-from|cache-to|buildx' "$wf" && ok "    build caching/buildx found" || warn "    no layer caching found"
    grep -qiE 'sha|github\.sha' "$wf" && ok "    commit SHA used in tagging" || warn "    confirm images are tagged with commit SHA"
    grep -qiE 'aws-actions/configure-aws-credentials|id-token: write|oidc' "$wf" && ok "    OIDC-based AWS auth referenced" || warn "    confirm OIDC is used instead of static AWS keys"
    grep -qiE 'ssm|ssh' "$wf" && ok "    deploy-to-EC2 step (SSM/SSH) found" || warn "    no deploy step to EC2 found"
    grep -qiE 'rollback' "$wf" && ok "    rollback logic referenced" || warn "    no rollback logic found"
    grep -qiE '\$\{\{ ?secrets\.' "$wf" && ok "    uses GitHub Secrets (no hardcoded creds expected)" || warn "    no secrets usage detected — confirm no hardcoded creds"
  done
else
  bad ".github/workflows/ missing"
fi

if f .env; then
  grep -qiE 'AKIA|aws_secret|password' .env && warn ".env contains values that look like real secrets — make sure .env is gitignored and never committed"
fi
if f .gitignore; then
  grep -q '^\.env$' .gitignore && ok ".env is gitignored" || bad ".env is NOT in .gitignore — risk of committed secrets"
else
  bad ".gitignore missing"
fi

# ---------------------------------------------------------------
section "Step 3: Infrastructure as Code (Terraform)"
# ---------------------------------------------------------------
if d terraform; then
  ok "terraform/ exists"
  f terraform/main.tf && ok "main.tf present" || bad "main.tf missing"
  f terraform/variables.tf && ok "variables.tf present" || bad "variables.tf missing"
  f terraform/outputs.tf && ok "outputs.tf present" || warn "outputs.tf missing"
  f terraform/backend.tf && grep -qi 's3' terraform/backend.tf && ok "S3 remote backend configured" || bad "no S3 backend found in backend.tf"
  grep -qi 'dynamodb\|use_lockfile' terraform/backend.tf 2>/dev/null && ok "state locking configured" || warn "confirm state locking (DynamoDB table or S3 native lockfile) is configured"
  d terraform/envs && ls terraform/envs/*.tfvars >/dev/null 2>&1 && ok "per-environment tfvars found (staging/prod)" || bad "no envs/*.tfvars found"
  grep -rqi 'aws_iam_instance_profile\|aws_iam_role' terraform/*.tf 2>/dev/null && ok "IAM instance profile/role defined" || bad "no IAM instance profile found"
  grep -rqi 'aws_security_group' terraform/*.tf 2>/dev/null && ok "security group defined" || bad "no security group found"
  grep -rqi 'cloudwatch' terraform/*.tf 2>/dev/null && ok "CloudWatch Logs referenced" || bad "no CloudWatch logging found"
  f terraform/user_data.sh.tftpl && ok "bootstrap/user_data template present" || bad "no user_data bootstrap script found"
  grep -rqi 'access_key\s*=\s*"' terraform/*.tf 2>/dev/null && bad "static AWS access key literal found in terraform .tf files!" || ok "no hardcoded AWS access keys found in .tf files"
else
  bad "terraform/ directory missing"
fi

if have terraform && d terraform; then
  echo "  running terraform validate (fmt check too)..."
  (cd terraform && terraform fmt -check -recursive >/tmp/tf_fmt.log 2>&1) && ok "terraform fmt clean" || warn "terraform fmt found formatting issues (/tmp/tf_fmt.log)"
  (cd terraform && terraform init -backend=false >/tmp/tf_init.log 2>&1 && terraform validate >/tmp/tf_validate.log 2>&1) \
    && ok "terraform validate passed" || warn "terraform validate failed or needs backend/providers (/tmp/tf_validate.log)"
else
  warn "terraform CLI not installed — install it to run validate/plan locally"
fi

f docs/terraform-evidence.txt && ok "terraform apply evidence file present" || warn "no terraform apply evidence found in docs/"

# ---------------------------------------------------------------
section "Step 4: Kubernetes Deployment"
# ---------------------------------------------------------------
if d k8s; then
  ok "k8s/ exists"
  f k8s/deployment.yaml && ok "deployment.yaml present" || bad "deployment.yaml missing"
  if f k8s/deployment.yaml; then
    grep -qi 'replicas: *[2-9]' k8s/deployment.yaml && ok "deployment has >=2 replicas" || bad "deployment does not clearly have >=2 replicas"
    grep -qi 'RollingUpdate' k8s/deployment.yaml && ok "rolling update strategy set" || warn "no explicit RollingUpdate strategy found"
    grep -qi 'livenessProbe' k8s/deployment.yaml && ok "livenessProbe present" || bad "livenessProbe missing"
    grep -qi 'readinessProbe' k8s/deployment.yaml && ok "readinessProbe present" || bad "readinessProbe missing"
    grep -qi 'resources:' k8s/deployment.yaml && grep -qi 'limits:' k8s/deployment.yaml && grep -qi 'requests:' k8s/deployment.yaml && ok "resource requests & limits set" || bad "resource requests/limits missing or incomplete"
    grep -qi 'runAsNonRoot' k8s/deployment.yaml && ok "securityContext runAsNonRoot set" || bad "runAsNonRoot not found"
    grep -qi 'readOnlyRootFilesystem: *true' k8s/deployment.yaml && ok "readOnlyRootFilesystem set" || bad "readOnlyRootFilesystem not found"
  fi
  f k8s/service.yaml && ok "service.yaml present" || bad "service.yaml missing"
  f k8s/ingress.yaml && ok "ingress.yaml present" || warn "ingress.yaml missing (ok if port-forward documented instead)"
  f k8s/configmap.yaml && ok "configmap.yaml present" || bad "configmap.yaml missing"
  (f k8s/examples/secret.example.yaml || f k8s/create-secret.sh) && ok "secret handling present (example/script, not plaintext secret)" || bad "no secret-handling approach found"
  f k8s/hpa.yaml && ok "HorizontalPodAutoscaler manifest present" || bad "hpa.yaml missing"
else
  bad "k8s/ directory missing"
fi

if have kubectl; then
  for file in k8s/*.yaml; do
    [ -f "$file" ] || continue
    kubectl apply --dry-run=client -f "$file" >/tmp/kubectl_dryrun.log 2>&1 \
      && ok "kubectl dry-run valid: $file" \
      || warn "kubectl dry-run failed for $file (no cluster context? /tmp/kubectl_dryrun.log)"
  done
else
  warn "kubectl not installed — can't dry-run validate manifests here"
fi

f docs/k8s-rollback.txt && ok "rollout/rollback demo evidence present" || bad "no k8s rollout/rollback evidence found in docs/"

# ---------------------------------------------------------------
section "Step 5: Observability Stack"
# ---------------------------------------------------------------
if f docker-compose.monitoring.yml; then
  ok "docker-compose.monitoring.yml exists"
  for svc in prometheus grafana loki alloy node-exporter cadvisor; do
    grep -qi "$svc" docker-compose.monitoring.yml && ok "service '$svc' referenced" || bad "service '$svc' NOT found in monitoring compose file"
  done
  grep -qi '8080:80\|3000:3000' docker-compose.monitoring.yml && ok "only Grafana looks host-exposed (spot check)" || warn "manually confirm only Grafana publishes a host port"
  grep -qi 'GF_SECURITY_ADMIN_PASSWORD' docker-compose.monitoring.yml && ok "Grafana admin password looks env/secret driven" || warn "confirm Grafana admin creds aren't hardcoded"
else
  bad "docker-compose.monitoring.yml missing"
fi

d monitoring && ok "monitoring/ config directory exists" || bad "monitoring/ directory missing"
f monitoring/prometheus/prometheus.yml && ok "prometheus.yml present" || bad "prometheus.yml missing"
f monitoring/prometheus/rules/alerts.yml && ok "alert rules file present" || bad "alert rules file missing"
if f monitoring/prometheus/rules/alerts.yml; then
  n=$(grep -c 'alert:' monitoring/prometheus/rules/alerts.yml 2>/dev/null || echo 0)
  if [ "$n" -ge 4 ]; then ok "found $n alert rules (>=4 required)"; else bad "only $n alert rules found (need >=4)"; fi
fi
f monitoring/loki/loki-config.yml && ok "Loki config present" || bad "Loki config missing"
f monitoring/alloy/config.alloy && ok "Grafana Alloy config present" || bad "Alloy config missing"
f monitoring/grafana/provisioning/datasources/datasources.yml && ok "Grafana datasources provisioned as code" || bad "Grafana datasources provisioning missing"
f monitoring/grafana/provisioning/dashboards/dashboards.yml && ok "Grafana dashboard provisioning config present" || bad "dashboard provisioning config missing"

ndash=$(ls monitoring/grafana/dashboards/*.json 2>/dev/null | wc -l)
if [ "$ndash" -ge 3 ]; then ok "$ndash dashboard JSON files found (need >=3)"; else bad "only $ndash dashboard JSON files found (need >=3: app/host/containers)"; fi
for d_ in application host containers; do
  f "monitoring/grafana/dashboards/${d_}.json" && ok "dashboard '${d_}.json' present" || bad "dashboard '${d_}.json' missing"
done

grep -rqi 'loki' monitoring/grafana/dashboards/*.json 2>/dev/null && ok "at least one dashboard references Loki (logs panel)" || warn "confirm one dashboard has a Loki logs panel next to metrics"

for s in docs/screenshots/dashboard-application.jpg docs/screenshots/dashboard-host.jpg docs/screenshots/dashboard-containers.jpg; do
  f "$s" && ok "screenshot present: $s" || bad "missing screenshot: $s"
done

# ---------------------------------------------------------------
section "Step 6: Linux Automation Scripting"
# ---------------------------------------------------------------
if f scripts/system_health.sh; then
  ok "scripts/system_health.sh exists"
  grep -q 'set -euo pipefail' scripts/system_health.sh && ok "set -euo pipefail present" || bad "set -euo pipefail missing"
  grep -qi -- '--json' scripts/system_health.sh && ok "--json flag supported" || bad "--json flag not found"
  grep -qi -- '--help' scripts/system_health.sh && ok "--help supported" || bad "--help not found"
  grep -qi -- '--disk' scripts/system_health.sh && grep -qi -- '--cpu' scripts/system_health.sh && grep -qi -- '--mem' scripts/system_health.sh && ok "configurable thresholds flags found" || bad "threshold flags (--disk/--cpu/--mem) not all found"
  grep -qi 'top 5\|head -5\|head -n 5' scripts/system_health.sh && ok "top-5 processes logic referenced" || warn "confirm top-5-by-memory logic exists"
  grep -qi 'exit 2\|exit 1\|exit 0' scripts/system_health.sh && ok "explicit exit codes used" || bad "explicit exit codes (0/1/2) not clearly found"
  grep -qi 'rotat' scripts/system_health.sh && ok "log rotation logic referenced" || bad "log rotation not found"
  if have shellcheck; then
    echo "  running shellcheck..."
    if shellcheck scripts/system_health.sh >/tmp/shellcheck.log 2>&1; then
      ok "shellcheck: no warnings"
    else
      warn "shellcheck reported issues — see /tmp/shellcheck.log"
    fi
  else
    warn "shellcheck not installed — install to verify 'passes with no warnings'"
  fi
else
  bad "scripts/system_health.sh missing"
fi

(f deploy/systemd/system-health.service && f deploy/systemd/system-health.timer) && ok "systemd service+timer present" || warn "no systemd unit/timer found (cron entry would also satisfy this)"

# ---------------------------------------------------------------
section "Step 7: Documentation (README.md)"
# ---------------------------------------------------------------
if f README.md; then
  ok "README.md exists"
  declare -A sections=(
    ["Design Decisions"]="design decision"
    ["Deployment"]="deployment.{0,20}rollback"
    ["Rollback"]="rollback"
    ["Security"]="security"
    ["cost"]="cost"
    ["improve"]="what i would improve|improvement"
    ["AI tools"]="ai tool|used ai"
  )
  for label in "${!sections[@]}"; do
    pattern="${sections[$label]}"
    grep -qiE "$pattern" README.md && ok "README mentions: $label" || bad "README missing section/content: $label"
  done
  grep -qi 'architecture' README.md && ok "README references an architecture diagram/section" || bad "no architecture diagram/section mentioned"
  grep -qi 'image size' README.md && ok "README states final image size" || bad "README does not state final Docker image size"
  grep -qi 'docker compose up\|docker-compose up' README.md && ok "README has docker compose run instructions" || bad "no docker compose instructions in README"
  grep -qi 'rollout undo' README.md && ok "README documents kubectl rollout undo" || bad "rollout undo not documented in README"
else
  bad "README.md missing"
fi

# ---------------------------------------------------------------
section "Git Practices"
# ---------------------------------------------------------------
if d .git; then
  nbranches=$(git branch -a 2>/dev/null | wc -l)
  [ "$nbranches" -gt 1 ] && ok "multiple branches used ($nbranches refs)" || warn "only default branch found — confirm feature branches/PRs were used"
  ncommits=$(git log --oneline 2>/dev/null | wc -l)
  echo "  total commits: $ncommits"
  [ "$ncommits" -ge 10 ] && ok "commit history looks reasonably granular ($ncommits commits)" || warn "few commits ($ncommits) — assessment values atomic, clear commits"
else
  warn "not a git repository (or .git missing) — can't check git practices"
fi

# ---------------------------------------------------------------
section "SUMMARY"
# ---------------------------------------------------------------
echo "PASS: $PASS   WARN: $WARN   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "=> Fix the [FAIL] items first — these are required-spec gaps."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "=> No hard failures, but review the [WARN] items manually before submitting."
  exit 0
else
  echo "=> All automated checks passed. Still re-read Step 7 requirements manually for quality/depth."
  exit 0
fi
