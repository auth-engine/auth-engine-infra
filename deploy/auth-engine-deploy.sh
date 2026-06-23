#!/usr/bin/env bash
# AuthEngine production deployment — Terraform, K3s/Rancher, Helm, seed, verify.
# Run from anywhere: ./deploy/auth-engine-deploy.sh [command]
#
# Commands:
#   plan              Terraform fmt → init → validate → plan (no changes)
#   apply             Terraform apply (requires prior plan review)
#   terraform         plan + interactive apply
#   outputs           Show Terraform outputs after apply
#   dns               Print DNS records to configure
#   k3s-guide         Print K3s + Rancher + cert-manager install steps
#   helm-values       Print Helm values checklist (secrets to override)
#   helm-install      Guided helm install authengine chart
#   k8s-migrate       Run auth-engine migrate in api pod (via SSM + kubectl)
#   k8s-seed          Run auth-engine-data all via kubectl Job (via SSM)
#   seed              Seed roles + super admin locally (auth-engine-data repo)
#   verify            Curl production health endpoints
#   oauth             OAuth redirect URI checklist
#   cicd              CI/CD (build + Rancher redeploy) checklist
#   docs              GitHub Pages docs setup (auth-engine-docs repo)
#   all               Interactive walk-through of every phase
#   help              Show usage
#
# Legacy (deprecated — use Helm/K8s commands above):
#   ses-dns, ec2-env, ec2-sync-compose, ec2-deploy, ec2-migrate, ec2-seed, nginx, nginx-manual
#
# Prerequisites:
#   - terraform >= 1.5, aws CLI (for SSM/kubectl on EC2)
#   - helm + kubectl (for helm-install; kubeconfig from K3s or Rancher)
#   - terraform/terraform.tfvars (copy from terraform.tfvars.example)
#
# Environment overrides:
#   TF_DIR, COMPOSE_DIR, TFVARS_FILE, AWS_REGION, AWS_PROFILE
#   SKIP_CONFIRM=1          Skip yes/no prompts (CI only)
#   AUTH_ENGINE_DATA_DIR    Path to auth-engine-data checkout (for local seed)
#   GITHUB_ORG              GitHub org for seed Job clone (default: auth-engine)
#   HELM_NAMESPACE          K8s namespace (default: authengine)
#   TF_AUTO_APPROVE=1       Pass -auto-approve to terraform apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform}"
COMPOSE_DIR="${COMPOSE_DIR:-${REPO_ROOT}/compose}"
TFVARS_FILE="${TFVARS_FILE:-${TF_DIR}/terraform.tfvars}"
AUTH_ENGINE_DATA_DIR="${AUTH_ENGINE_DATA_DIR:-${REPO_ROOT}/../auth-engine-data}"
GITHUB_ORG="${GITHUB_ORG:-auth-engine}"
HELM_DIR="${HELM_DIR:-${REPO_ROOT}/helm/authengine}"
HELM_NAMESPACE="${HELM_NAMESPACE:-authengine}"
NGINX_DIR="${NGINX_DIR:-${SCRIPT_DIR}/nginx}"
NGINX_TEMPLATE="${NGINX_TEMPLATE:-${NGINX_DIR}/authengine.http.conf.tpl}"
PLAN_FILE="${TF_DIR}/tfplan"
OUTPUTS_FILE="${SCRIPT_DIR}/last-terraform-outputs.json"

# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()   { printf '%b\n' "${BLUE}[INFO]${NC} $*"; }
ok()    { printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn()  { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
err()   { printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
phase() { printf '\n%b\n' "${BOLD}══════════════════════════════════════════════${NC}"; printf '%b\n' "${BOLD}  Phase $*${NC}"; printf '%b\n' "${BOLD}══════════════════════════════════════════════${NC}"; }

confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${SKIP_CONFIRM:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Required command not found: ${cmd}"
    exit 1
  fi
}

aws_cli() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --profile "${AWS_PROFILE}" "$@"
  else
    aws "$@"
  fi
}

terraform_cmd() {
  local extra_env=()
  if [[ -n "${AWS_REGION:-}" ]]; then
    extra_env+=(AWS_REGION="${AWS_REGION}")
  fi
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    extra_env+=(AWS_PROFILE="${AWS_PROFILE}")
  fi
  env "${extra_env[@]}" terraform -chdir="${TF_DIR}" "$@"
}

tf_output() {
  local name="$1"
  terraform_cmd output -raw "${name}" 2>/dev/null || true
}

tf_var() {
  local key="$1"
  local default="${2:-}"
  if [[ ! -f "${TFVARS_FILE}" ]]; then
    printf '%s' "${default}"
    return
  fi
  local value
  value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS_FILE}" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/; s/^[^=]*=[[:space:]]*([^[:space:]#]+).*/\1/')"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${default}"
  fi
}

load_domain_config() {
  ROOT_DOMAIN="${ROOT_DOMAIN:-$(tf_var root_domain authengine.org)}"
  API_SUBDOMAIN="${API_SUBDOMAIN:-$(tf_var api_subdomain api)}"
  IDP_SUBDOMAIN="${IDP_SUBDOMAIN:-$(tf_var idp_subdomain auth)}"
  APP_SUBDOMAIN="${APP_SUBDOMAIN:-$(tf_var dashboard_subdomain app)}"
  API_HOST="${API_SUBDOMAIN}.${ROOT_DOMAIN}"
  IDP_HOST="${IDP_SUBDOMAIN}.${ROOT_DOMAIN}"
  APP_HOST="${APP_SUBDOMAIN}.${ROOT_DOMAIN}"
}

render_nginx_conf() {
  local out="$1"
  load_domain_config
  if [[ ! -f "${NGINX_TEMPLATE}" ]]; then
    err "nginx template not found: ${NGINX_TEMPLATE}"
    return 1
  fi
  sed \
    -e "s/@ROOT_DOMAIN@/${ROOT_DOMAIN}/g" \
    -e "s/@API_HOST@/${API_HOST}/g" \
    -e "s/@IDP_HOST@/${IDP_HOST}/g" \
    -e "s/@APP_HOST@/${APP_HOST}/g" \
    "${NGINX_TEMPLATE}" >"${out}"
}

tf_state_ready() {
  terraform_cmd output -json >/dev/null 2>&1
}

save_outputs() {
  if tf_state_ready; then
    terraform_cmd output -json >"${OUTPUTS_FILE}"
    ok "Terraform outputs saved to ${OUTPUTS_FILE}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — Terraform
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
  phase "0 — Prerequisites"
  require_cmd terraform
  log "Terraform: $(terraform version | head -1)"

  if [[ ! -f "${TFVARS_FILE}" ]]; then
    err "Missing ${TFVARS_FILE}"
    log "Create it from the example:"
    log "  cp ${TF_DIR}/terraform.tfvars.example ${TFVARS_FILE}"
    log "  # Set ec2_instance_type = t4g.xlarge for production"
    exit 1
  fi
  ok "Found ${TFVARS_FILE}"

  if grep -q 'CHANGE_ME' "${TFVARS_FILE}" 2>/dev/null; then
    warn "terraform.tfvars still contains CHANGE_ME placeholders — update before apply"
  fi

  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI: $(aws --version 2>&1 | head -1)"
    if aws_cli sts get-caller-identity >/dev/null 2>&1; then
      ok "AWS credentials valid: $(aws_cli sts get-caller-identity --query Arn --output text)"
    else
      warn "AWS credentials not configured — EC2/SSM steps will be skipped"
    fi
  else
    warn "AWS CLI not installed — EC2/SSM remote steps unavailable"
  fi
}

phase_terraform_fmt() {
  log "Checking Terraform formatting..."
  terraform_cmd fmt -check -recursive
  ok "Terraform format OK"
}

phase_terraform_init() {
  log "Running terraform init..."
  terraform_cmd init -upgrade
  ok "terraform init complete"
}

phase_terraform_validate() {
  log "Running terraform validate..."
  terraform_cmd validate
  ok "terraform validate OK"
}

phase_terraform_plan() {
  log "Running terraform plan..."
  terraform_cmd plan -input=false -out="${PLAN_FILE}"
  ok "Plan saved to ${PLAN_FILE}"
  warn "Review the plan above before applying."
}

phase_terraform_apply() {
  if [[ ! -f "${PLAN_FILE}" ]]; then
    warn "No saved plan at ${PLAN_FILE} — running fresh plan before apply"
    phase_terraform_plan
  fi

  if [[ "${TF_AUTO_APPROVE:-0}" == "1" ]]; then
    log "Applying with -auto-approve (TF_AUTO_APPROVE=1)"
    terraform_cmd apply -input=false -auto-approve "${PLAN_FILE}"
  else
    if ! confirm "Apply Terraform plan? This will create/modify AWS resources."; then
      warn "Apply cancelled"
      return 1
    fi
    terraform_cmd apply -input=false "${PLAN_FILE}"
  fi

  ok "terraform apply complete"
  save_outputs
  rm -f "${PLAN_FILE}"
}

cmd_plan() {
  check_prerequisites
  phase "1a — Terraform Plan"
  phase_terraform_fmt
  phase_terraform_init
  phase_terraform_validate
  phase_terraform_plan
}

cmd_apply() {
  check_prerequisites
  phase "1b — Terraform Apply"
  phase_terraform_init
  phase_terraform_apply
}

cmd_terraform() {
  cmd_plan
  cmd_apply
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — DNS
# ─────────────────────────────────────────────────────────────────────────────

cmd_dns() {
  phase "2 — DNS"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local eip
  eip="$(tf_output ec2_public_ip)"

  cat <<EOF

Point these DNS records at your registrar (TTL 300 during migration):

  Type   Host    Target
  ─────────────────────────────────────────────────────
  A      @       ${eip}
  A      www     ${eip}   (optional)
  A      api     ${eip}
  A      auth    ${eip}
  A      app     ${eip}
  A      rancher ${eip}
  CNAME  docs    auth-engine.github.io  (GitHub Pages — auth-engine-docs repo)

Terraform no longer exposes the old 'suggested_urls' output.
Use the EC2 Elastic IP above for any subdomains you want to route to this host.
EOF
}

cmd_ses_dns() {
  warn "SES is no longer provisioned by Terraform. Use Resend for email (see helm values secrets.resendApiKey)."
  warn "See: auth-engine-docs/docs/deployment.md — Phase 5 (Seed data / platform config)"
}

cmd_k3s_guide() {
  phase "3 — K3s and Rancher"
  load_domain_config
  local instance_id
  instance_id="$(tf_output ec2_instance_id 2>/dev/null || echo 'i-xxxxxxxx')"

  cat <<EOF

Connect to EC2:

  aws ssm start-session --target ${instance_id}

Install K3s:

  curl -sfL https://get.k3s.io | sh -
  sudo k3s kubectl get nodes

Install Helm:

  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 get_helm.sh && ./get_helm.sh

Install cert-manager + Rancher (DNS for rancher.${ROOT_DOMAIN} must point to EC2 first):

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  helm repo add jetstack https://charts.jetstack.io && helm repo update
  helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true
  helm install rancher rancher-latest/rancher --namespace cattle-system --create-namespace \\
    --set hostname=rancher.${ROOT_DOMAIN} --set replicas=1 --set bootstrapPassword=admin

Open https://rancher.${ROOT_DOMAIN} and change the bootstrap password.

Full guide: https://docs.authengine.org/deployment/

EOF
}

cmd_helm_values() {
  phase "4a — Helm values checklist"
  load_domain_config

  cat <<EOF

Create a prod override file (do not commit secrets):

  cd ${HELM_DIR}
  cp values.yaml prod-values.yaml

Set at minimum:

  global.domain: ${ROOT_DOMAIN}
  secrets.postgresPassword, mongoPassword, redisPassword
  secrets.secretKey, jwtSecretKey  (openssl rand -hex 32)
  secrets.resendApiKey              (Resend — recommended for email)
  seed.enabled: true                (first deploy only)
  seed.superadminEmail / superadminPassword

Production URLs (set automatically by the chart from global.*):

  APP_URL=https://${IDP_HOST}
  DASHBOARD_URL=https://${APP_HOST}

Install:

  helm install authengine . --namespace ${HELM_NAMESPACE} --create-namespace -f prod-values.yaml

EOF
}

cmd_helm_install() {
  phase "4 — Helm install"
  require_cmd helm
  if [[ ! -f "${HELM_DIR}/Chart.yaml" ]]; then
    err "Helm chart not found: ${HELM_DIR}"
    exit 1
  fi
  cmd_helm_values
  if ! confirm "Run helm install now (requires kubectl context)?"; then
    warn "Skipped — run manually when kubeconfig is ready"
    return 0
  fi
  helm install authengine "${HELM_DIR}" \
    --namespace "${HELM_NAMESPACE}" \
    --create-namespace \
    ${HELM_VALUES_FILE:+-f "${HELM_VALUES_FILE}"}
  ok "Helm release installed. Check: kubectl -n ${HELM_NAMESPACE} get pods"
}

k8s_kubectl_ssm() {
  local comment="$1"
  shift
  local instance_id
  instance_id="$(tf_output ec2_instance_id)"
  if [[ -z "${instance_id}" ]]; then
    err "ec2_instance_id not in Terraform state"
    return 1
  fi
  run_ssm_command "${instance_id}" "${comment}" \
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" \
    "$@"
}

cmd_k8s_migrate() {
  phase "Migrate — auth-engine migrate in api pod"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi
  if ! confirm "Run auth-engine migrate via kubectl on EC2?"; then
    warn "Skipped"
    return 0
  fi
  k8s_kubectl_ssm "auth-engine-k8s-migrate" \
    "kubectl -n ${HELM_NAMESPACE} exec deployment/api -- auth-engine migrate"
}

cmd_k8s_seed() {
  phase "Seed — auth-engine-data all via kubectl Job"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi
  warn "Requires SUPERADMIN_EMAIL/PASSWORD — set seed.* in Helm values or pass env to Job"
  if ! confirm "Run seed Job on cluster via SSM?"; then
    warn "Skipped — or enable seed.enabled in Helm values and helm upgrade"
    return 0
  fi
  k8s_kubectl_ssm "auth-engine-k8s-seed" \
    "kubectl -n ${HELM_NAMESPACE} delete job authengine-seed --ignore-not-found=true" \
    "helm upgrade authengine ${HELM_DIR} --namespace ${HELM_NAMESPACE} --reuse-values --set seed.enabled=true"
}

cmd_ec2_env() {
  warn "Deprecated: production uses Helm/K3s, not /opt/authengine/.env on EC2."
  cmd_helm_values
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — EC2 containers (via SSM)
# ─────────────────────────────────────────────────────────────────────────────

# AL2023 ships docker without the compose plugin; install v2 CLI plugin if missing.
ensure_docker_compose_ssm_cmd='if ! docker compose version >/dev/null 2>&1; then ARCH=$(uname -m); mkdir -p /usr/local/lib/docker/cli-plugins; curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-${ARCH}" -o /usr/local/lib/docker/cli-plugins/docker-compose; chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; fi'

file_b64() {
  local f="$1"
  base64 -w0 "${f}" 2>/dev/null || base64 <"${f}" | tr -d '\n'
}

run_ssm_command() {
  local instance_id="$1"
  shift
  local comment="${1:-auth-engine-deploy}"
  shift || true

  if ! command -v aws >/dev/null 2>&1; then
    err "AWS CLI required for remote EC2 commands"
    return 1
  fi

  local params_file
  params_file="$(mktemp)"
  # Build JSON array of shell commands for SSM
  {
    printf '{"commands":['
    local first=true
    for cmd in "$@"; do
      if [[ "${first}" == true ]]; then first=false; else printf ','; fi
      printf '%s' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${cmd}")"
    done
    printf ']}'
  } >"${params_file}"

  log "Sending SSM command to ${instance_id}..."
  local command_id
  command_id="$(aws_cli ssm send-command \
    --instance-ids "${instance_id}" \
    --document-name "AWS-RunShellScript" \
    --comment "${comment}" \
    --parameters "file://${params_file}" \
    --query 'Command.CommandId' \
    --output text)"
  rm -f "${params_file}"

  log "SSM command ID: ${command_id} — waiting..."
  local status="InProgress"
  while [[ "${status}" == "InProgress" || "${status}" == "Pending" ]]; do
    sleep 3
    status="$(aws_cli ssm get-command-invocation \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query 'Status' \
      --output text 2>/dev/null || echo InProgress)"
  done

  local output
  output="$(aws_cli ssm get-command-invocation \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' \
    --output text)"

  # SSM output can be huge (apt/uv logs); show the tail so the terminal pager is usable.
  local line_count
  line_count="$(printf '%s' "${output}" | wc -l)"
  if [[ "${line_count}" -gt 45 ]]; then
    warn "SSM output truncated to last 40 lines (${line_count} total)"
    printf '%s\n' "${output}" | tail -40
  else
    printf '%s\n' "${output}"
  fi

  if [[ "${status}" != "Success" ]]; then
    err "SSM command failed with status: ${status}"
    return 1
  fi
  ok "SSM command succeeded"
}

cmd_ec2_sync_compose() {
  warn "Deprecated: production uses Helm on K3s. Local dev: cd compose && docker compose up -d"
}

cmd_ec2_deploy() {
  warn "Deprecated: use helm-install or Rancher UI to deploy workloads."
  cmd_helm_install
}

cmd_ec2_migrate() {
  warn "Deprecated: use k8s-migrate"
  cmd_k8s_migrate
}

cmd_ec2_seed() {
  warn "Deprecated: use k8s-seed or seed.enabled in Helm values"
  cmd_k8s_seed
}

cmd_seed() {
  phase "Seed roles and super admin (local)"
  if [[ ! -d "${AUTH_ENGINE_DATA_DIR}" ]]; then
    err "auth-engine-data not found at ${AUTH_ENGINE_DATA_DIR}"
    log "Clone it: git clone https://github.com/${GITHUB_ORG}/auth-engine-data.git"
    log "Or set AUTH_ENGINE_DATA_DIR=/path/to/auth-engine-data"
    exit 1
  fi

  require_cmd uv

  local env_local="${AUTH_ENGINE_DATA_DIR}/.env.local"
  if [[ ! -f "${env_local}" ]]; then
    if [[ -f "${COMPOSE_DIR}/.env" ]]; then
      log "Copying compose/.env → auth-engine-data/.env.local"
      cp "${COMPOSE_DIR}/.env" "${env_local}"
    elif [[ -f "${COMPOSE_DIR}/env.local.example" ]]; then
      warn "No .env.local found — copy env.local.example first"
      cp "${COMPOSE_DIR}/env.local.example" "${env_local}"
      err "Edit ${env_local} then re-run"
      exit 1
    else
      err "No .env.local in ${AUTH_ENGINE_DATA_DIR}"
      exit 1
    fi
  fi

  warn "For production K8s, use k8s-seed or seed.enabled in Helm values."
  if ! confirm "Run auth-engine-data all locally?"; then
    warn "Skipped"
    return 0
  fi

  log "Seeding from ${AUTH_ENGINE_DATA_DIR}..."
  (cd "${AUTH_ENGINE_DATA_DIR}" && uv sync && uv run auth-engine-data all)
  ok "Seed complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 — nginx + TLS
# ─────────────────────────────────────────────────────────────────────────────

cmd_nginx() {
  warn "Deprecated: TLS is handled by cert-manager + Ingress on K3s, not nginx on EC2."
  cmd_nginx_manual
}

cmd_nginx_manual() {
  warn "Deprecated for production. Use Helm ingress + cert-manager (see k3s-guide)."
  load_domain_config
  cat <<EOF

SSH/SSM into EC2 and create /etc/nginx/conf.d/authengine.conf (HTTP first):

  # api + auth → :8000
  server {
      listen 80;
      server_name ${API_HOST} ${IDP_HOST};
      location / {
          proxy_pass http://127.0.0.1:8000;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
      }
  }

  # dashboard → :3000
  server {
      listen 80;
      server_name ${APP_HOST};
      location / {
          proxy_pass http://127.0.0.1:3000;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
      }
  }

  # apex → app
  server {
      listen 80;
      server_name ${ROOT_DOMAIN} www.${ROOT_DOMAIN};
      return 302 http://${APP_HOST}\$request_uri;
  }

Then:

  sudo nginx -t
  sudo systemctl reload nginx
  sudo certbot --nginx -d ${API_HOST} -d ${IDP_HOST} -d ${APP_HOST} -d ${ROOT_DOMAIN} -d www.${ROOT_DOMAIN}

Or automate: ./deploy/auth-engine-deploy.sh nginx

Full guide: auth-engine-docs/docs/deployment.md

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6–8 — Checklists
# ─────────────────────────────────────────────────────────────────────────────

cmd_oauth() {
  phase "6 — OAuth redirect URIs"
  cat <<'EOF'

Register these redirect URIs in each provider console:

  https://api.authengine.org/api/v1/auth/oauth/google/callback
  https://api.authengine.org/api/v1/auth/oauth/github/callback
  https://api.authengine.org/api/v1/auth/oauth/microsoft/callback
  https://app.authengine.org/oauth/authengine/callback

EOF
}

cmd_cicd() {
  phase "7 — CI/CD (build images; redeploy in Rancher)"
  cat <<EOF

Merge to \`main\` in each app repo triggers:

  0-ci (lint) → 1-build-push (Docker Hub :latest)

There is **no** automatic cluster deploy. After a new image is pushed:

| Repo | Redeploy |
|------|----------|
| auth-engine | Rancher → \`api\` workload → Redeploy (or \`kubectl rollout restart deployment/api -n ${HELM_NAMESPACE}\`) |
| auth-engine-dashboard | Rancher → \`dashboard\` workload → Redeploy |

After API releases, run migrations:

  ./deploy/auth-engine-deploy.sh k8s-migrate

GitHub secrets (both app repos):

  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN

First deploy only — enable seed in Helm values or run:

  ./deploy/auth-engine-deploy.sh k8s-seed

Full guide: https://docs.authengine.org/deployment/

EOF
}

cmd_docs() {
  phase "8 — Documentation site (docs.authengine.org)"
  cat <<'EOF'

Docs are in the **auth-engine-docs** repository — served from GitHub Pages, NOT from EC2.

1. auth-engine-docs Settings → Pages → Source: GitHub Actions
2. Run workflow: auth-engine-docs · Deploy docs (workflow_dispatch)
3. Custom domain: docs.authengine.org (docs/CNAME in repo)
4. DNS: CNAME docs → auth-engine.github.io
5. Enable "Enforce HTTPS" in Pages settings

Do NOT run certbot for docs on EC2.

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 9 — Verification
# ─────────────────────────────────────────────────────────────────────────────

cmd_verify() {
  phase "9 — Production verification"
  require_cmd curl

  local checks=(
    "API health|https://api.authengine.org/api/v1/health"
    "OIDC discovery|https://api.authengine.org/.well-known/openid-configuration"
    "Swagger|https://api.authengine.org/docs"
    "Dashboard|https://app.authengine.org/login"
    "Docs|https://docs.authengine.org"
  )

  for entry in "${checks[@]}"; do
    local name="${entry%%|*}"
    local url="${entry##*|}"
    log "Checking ${name}: ${url}"
    if curl -fsSI --max-time 15 "${url}" >/dev/null 2>&1; then
      ok "${name} reachable"
    else
      warn "${name} not reachable (DNS/TLS/containers may not be ready yet)"
    fi
  done
}

cmd_outputs() {
  phase "Terraform outputs"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi
  terraform_cmd output
  save_outputs
}

# ─────────────────────────────────────────────────────────────────────────────
# Full interactive deployment
# ─────────────────────────────────────────────────────────────────────────────

cmd_all() {
  log "AuthEngine full deployment walk-through"
  log "Repository: ${REPO_ROOT}"
  echo ""

  check_prerequisites

  phase "1 — Terraform"
  phase_terraform_fmt
  phase_terraform_init
  phase_terraform_validate
  phase_terraform_plan

  if confirm "Proceed to terraform apply?"; then
    phase_terraform_apply
  else
    warn "Skipping apply — run '$0 apply' when ready"
  fi

  cmd_outputs
  cmd_dns

  cmd_k3s_guide
  if ! confirm "Have you installed K3s and Rancher on EC2?"; then
    warn "Complete K3s/Rancher setup before continuing."
    return 0
  fi

  cmd_helm_values
  if command -v helm >/dev/null 2>&1 && confirm "Run helm install now?"; then
    cmd_helm_install
  fi

  if command -v aws >/dev/null 2>&1 && aws_cli sts get-caller-identity >/dev/null 2>&1; then
    if confirm "Run k8s migrate via SSM?"; then
      cmd_k8s_migrate
    fi
    if confirm "Seed roles and super admin (first deploy only)?"; then
      cmd_k8s_seed
    fi
  else
    warn "AWS CLI unavailable — run k8s-migrate and k8s-seed manually"
  fi

  cmd_oauth
  cmd_cicd
  cmd_docs

  if confirm "Run production verification checks?"; then
    cmd_verify
  fi

  ok "Deployment walk-through complete"
  log "Full guide: auth-engine-docs/docs/deployment.md"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Terraform:
  plan        Format, init, validate, and plan (no changes)
  apply       Apply saved plan (or plan + apply interactively)
  terraform   plan + apply in one run
  outputs     Show and save Terraform outputs

Infrastructure setup:
  dns           DNS A/CNAME records for EC2 + docs
  k3s-guide     K3s + Rancher + cert-manager install steps
  helm-values   Helm secrets checklist
  helm-install  Install authengine Helm chart

Kubernetes (requires AWS CLI + SSM + K3s on EC2):
  k8s-migrate   Run auth-engine migrate in api pod
  k8s-seed      Enable/run seed Job (roles + super admin)
  seed          Seed locally via auth-engine-data (compose dev)

Deprecated (legacy Compose/EC2):
  ses-dns, ec2-env, ec2-sync-compose, ec2-deploy, ec2-migrate, ec2-seed, nginx, nginx-manual

Manual checklists:
  oauth         OAuth redirect URI checklist
  cicd          CI/CD (build + Rancher redeploy)
  docs          GitHub Pages docs setup (auth-engine-docs)

Verification:
  verify      Curl production endpoints

All phases:
  all         Interactive full deployment walk-through

Environment:
  TF_DIR=${TF_DIR}
  TFVARS_FILE=${TFVARS_FILE}
  AWS_PROFILE, AWS_REGION, HELM_NAMESPACE, HELM_VALUES_FILE
  AUTH_ENGINE_DATA_DIR, GITHUB_ORG
  SKIP_CONFIRM=1, TF_AUTO_APPROVE=1

Examples:
  $(basename "$0") plan
  $(basename "$0") apply
  $(basename "$0") k3s-guide
  HELM_VALUES_FILE=helm/authengine/prod-values.yaml $(basename "$0") helm-install
  $(basename "$0") all

EOF
}

main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    plan)        cmd_plan "$@" ;;
    apply)       cmd_apply "$@" ;;
    terraform)   cmd_terraform "$@" ;;
    outputs)     cmd_outputs "$@" ;;
    dns)         cmd_dns "$@" ;;
    ses-dns)     cmd_ses_dns "$@" ;;
    k3s-guide)   cmd_k3s_guide "$@" ;;
    helm-values) cmd_helm_values "$@" ;;
    helm-install) cmd_helm_install "$@" ;;
    k8s-migrate) cmd_k8s_migrate "$@" ;;
    k8s-seed)    cmd_k8s_seed "$@" ;;
    ec2-env)     cmd_ec2_env "$@" ;;
    ec2-sync-compose) cmd_ec2_sync_compose "$@" ;;
    ec2-deploy)  cmd_ec2_deploy "$@" ;;
    ec2-migrate) cmd_ec2_migrate "$@" ;;
    ec2-seed)    cmd_ec2_seed "$@" ;;
    seed)        cmd_seed "$@" ;;
    nginx)       cmd_nginx "$@" ;;
    nginx-manual) cmd_nginx_manual "$@" ;;
    oauth)       cmd_oauth "$@" ;;
    cicd)        cmd_cicd "$@" ;;
    docs)        cmd_docs "$@" ;;
    verify)      cmd_verify "$@" ;;
    all)         cmd_all "$@" ;;
    help|-h|--help) usage ;;
    *)
      err "Unknown command: ${command}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
