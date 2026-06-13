#!/usr/bin/env bash
# AuthEngine production deployment — Terraform plan/apply through verification.
# Run from anywhere: ./deploy/auth-engine-deploy.sh [command]
#
# Commands:
#   plan              Terraform fmt → init → validate → plan (no changes)
#   apply             Terraform apply (requires prior plan review)
#   terraform         plan + interactive apply
#   outputs           Show Terraform outputs after apply
#   dns               Print DNS records to configure
#   ses-dns           Print SES DNS records from Terraform
#   ec2-env           Print EC2 .env setup instructions
#   ec2-sync-compose  Copy compose files to EC2 (no docker pull/up)
#   ec2-deploy        Pull images and start containers on EC2 (via SSM)
#   ec2-migrate       Run database migrations on EC2 (via SSM)
#   ec2-seed          Seed roles + super admin on EC2 (via SSM, after migrate)
#   seed              Seed roles + super admin locally (auth-engine-data repo)
#   nginx             Install nginx + certbot on EC2 and issue TLS certs (SSM)
#   nginx-manual      Print manual nginx + certbot instructions
#   verify            Curl production health endpoints
#   all               Interactive walk-through of every phase
#   help              Show usage
#
# Prerequisites:
#   - terraform >= 1.5, aws CLI (for SSM/EC2 steps)
#   - AWS credentials (env vars or ~/.aws/credentials)
#   - terraform/terraform.tfvars with db_password set
#
# Environment overrides:
#   TF_DIR, COMPOSE_DIR, TFVARS_FILE, AWS_REGION, AWS_PROFILE
#   SKIP_CONFIRM=1          Skip yes/no prompts (CI only)
#   AUTH_ENGINE_DATA_DIR    Path to auth-engine-data checkout (for local seed)
#   GITHUB_ORG              GitHub org for clone-based EC2 seed (default: auth-engine)
#   CERTBOT_EMAIL           Let's Encrypt contact (default: SUPERADMIN_EMAIL on EC2)
#   TF_AUTO_APPROVE=1       Pass -auto-approve to terraform apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform}"
COMPOSE_DIR="${COMPOSE_DIR:-${REPO_ROOT}/compose}"
TFVARS_FILE="${TFVARS_FILE:-${TF_DIR}/terraform.tfvars}"
AUTH_ENGINE_DATA_DIR="${AUTH_ENGINE_DATA_DIR:-${REPO_ROOT}/../auth-engine-data}"
GITHUB_ORG="${GITHUB_ORG:-auth-engine}"
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
  if [[ -n "${TF_VAR_db_password:-}" ]]; then
    extra_env+=(TF_VAR_db_password="${TF_VAR_db_password}")
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
    log "  # Set db_password (openssl rand -base64 24)"
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
  CNAME  docs    <your-github-pages-host>  (e.g. auth-engine.github.io)

Suggested URLs (from terraform output suggested_urls):
EOF
  terraform_cmd output suggested_urls
}

cmd_ses_dns() {
  phase "2b — SES DNS"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  log "SES from address: $(tf_output ses_from_address)"
  echo ""
  terraform_cmd output -json ses_dns_records 2>/dev/null | python3 -m json.tool || terraform_cmd output ses_dns_records
  echo ""
  log "Production access CLI:"
  terraform_cmd output ses_production_access_cli 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — EC2 environment
# ─────────────────────────────────────────────────────────────────────────────

cmd_ec2_env() {
  phase "3 — EC2 application environment"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local instance_id eip rds_endpoint postgres_template
  instance_id="$(tf_output ec2_instance_id)"
  eip="$(tf_output ec2_public_ip)"
  rds_endpoint="$(tf_output rds_endpoint)"
  postgres_template="$(tf_output postgres_url_template)"

  cat <<EOF

Connect to EC2 (SSM — no SSH key required):

  aws ssm start-session --target ${instance_id}

On the EC2 instance:

  sudo mkdir -p /opt/authengine
  sudo cp ${COMPOSE_DIR}/env.prod.example /opt/authengine/.env
  sudo nano /opt/authengine/.env
  sudo chmod 600 /opt/authengine/.env

Fill in these values:

  EC2 Elastic IP:     ${eip}
  RDS endpoint:       ${rds_endpoint}
  POSTGRES_URL:       ${postgres_template}
  MONGODB_URL:        <MongoDB Atlas M0 — must include /authengine in path>
  REDIS_URL:          <Upstash rediss:// URL>
  SECRET_KEY:         openssl rand -hex 32
  JWT_SECRET_KEY:     openssl rand -hex 32
  SUPERADMIN_EMAIL / SUPERADMIN_PASSWORD
  OAuth client IDs and secrets
  SMS_GATEWAY_USERNAME / SMS_GATEWAY_PASSWORD

Optional OIDC RS256 key:

  sudo openssl genrsa -out /opt/authengine/oidc_private.pem 2048
  UID=\$(docker run --rm qniranjan01/authengine:latest id -u authengine)
  sudo chown \$UID:\$UID /opt/authengine/oidc_private.pem
  sudo chmod 400 /opt/authengine/oidc_private.pem

Or copy a local key:

  scp deploy/oidc.pem ec2-user@${eip}:/tmp/oidc_private.pem
  # then move + chown on EC2

EOF
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
  phase "3b — Sync compose files to EC2"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local instance_id compose_b64 env_b64
  instance_id="$(tf_output ec2_instance_id)"
  compose_b64="$(file_b64 "${COMPOSE_DIR}/docker-compose.prod.yml")"
  env_b64="$(file_b64 "${COMPOSE_DIR}/env.prod.example")"

  log "Instance: ${instance_id}"
  log "Copying docker-compose.prod.yml and env.prod.example → /opt/authengine/"

  run_ssm_command "${instance_id}" "auth-engine-sync-compose" \
    "set -euo pipefail" \
    "mkdir -p /opt/authengine/compose" \
    "echo '${compose_b64}' | base64 -d > /opt/authengine/compose/docker-compose.prod.yml" \
    "echo '${env_b64}' | base64 -d > /opt/authengine/env.prod.example" \
    "if [[ ! -f /opt/authengine/.env ]]; then cp /opt/authengine/env.prod.example /opt/authengine/.env && chmod 600 /opt/authengine/.env; fi" \
    "ls -la /opt/authengine /opt/authengine/compose"

  ok "Files on EC2:"
  log "  /opt/authengine/compose/docker-compose.prod.yml"
  log "  /opt/authengine/env.prod.example"
  warn "Edit /opt/authengine/.env on EC2 before ec2-deploy (SSM: aws ssm start-session --target ${instance_id})"
}

cmd_ec2_deploy() {
  phase "4 — Start containers on EC2"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local instance_id
  instance_id="$(tf_output ec2_instance_id)"

  log "Instance: ${instance_id}"
  log "Images: qniranjan01/authengine:latest, qniranjan01/authengine-dashboard:latest"

  if ! confirm "Pull and start containers on EC2 via SSM?"; then
    warn "Skipped"
    return 0
  fi

  # Sync compose manifest to EC2 and start containers
  local compose_b64
  compose_b64="$(file_b64 "${COMPOSE_DIR}/docker-compose.prod.yml")"

  run_ssm_command "${instance_id}" "auth-engine-deploy-containers" \
    "set -euo pipefail" \
    "${ensure_docker_compose_ssm_cmd}" \
    "mkdir -p /opt/authengine/compose" \
    "echo '${compose_b64}' | base64 -d > /opt/authengine/compose/docker-compose.prod.yml" \
    "cd /opt/authengine/compose" \
    "export ENV_FILE=/opt/authengine/.env" \
    "export OIDC_PRIVATE_KEY_PATH=/opt/authengine/oidc_private.pem" \
    "docker compose --env-file /opt/authengine/.env -f docker-compose.prod.yml pull" \
    "docker compose --env-file /opt/authengine/.env -f docker-compose.prod.yml up -d" \
    "docker compose --env-file /opt/authengine/.env -f docker-compose.prod.yml ps"
}

cmd_ec2_migrate() {
  phase "4b — Database migrations"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local instance_id
  instance_id="$(tf_output ec2_instance_id)"

  if ! confirm "Run auth-engine migrate on EC2?"; then
    warn "Skipped"
    return 0
  fi

  run_ssm_command "${instance_id}" "auth-engine-migrate" \
    "docker exec authengine-api auth-engine migrate"
}

cmd_ec2_seed() {
  phase "4c — Seed roles and super admin"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi

  local instance_id
  instance_id="$(tf_output ec2_instance_id)"

  warn "Seeding requires SUPERADMIN_EMAIL and SUPERADMIN_PASSWORD in /opt/authengine/.env"
  warn "Run only after migrate. RDS is private — seeding runs on EC2, not your laptop."

  if ! confirm "Seed roles + super admin on EC2 via SSM?"; then
    warn "Skipped"
    return 0
  fi

  # Clone auth-engine + auth-engine-data in a one-off container; reuse /opt/authengine/.env
  run_ssm_command "${instance_id}" "auth-engine-seed" \
    "set -euo pipefail" \
    "test -f /opt/authengine/.env" \
    "docker run --rm -v /opt/authengine/.env:/seed/.env.local:ro python:3.12-slim-bookworm bash -lc 'set -e; apt-get update -qq && apt-get install -y -qq git curl ca-certificates; curl -LsSf https://astral.sh/uv/install.sh | sh; export PATH=\"/root/.local/bin:\$PATH\"; git clone --depth 1 https://github.com/${GITHUB_ORG}/auth-engine.git /tmp/auth-engine; git clone --depth 1 https://github.com/${GITHUB_ORG}/auth-engine-data.git /tmp/auth-engine-data; cp /seed/.env.local /tmp/auth-engine-data/.env.local; cd /tmp/auth-engine-data && uv sync && uv run auth-engine-data all'"
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

  warn "For production RDS, use ec2-seed (RDS is not reachable from your laptop)."
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

cmd_nginx_manual() {
  phase "5 — nginx and TLS (manual on EC2)"
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

cmd_nginx() {
  phase "5 — nginx and TLS on EC2"
  if ! tf_state_ready; then
    err "No Terraform state found. Run: $0 apply"
    exit 1
  fi
  if ! command -v aws >/dev/null 2>&1; then
    err "AWS CLI required. Run: $0 nginx-manual"
    exit 1
  fi

  local instance_id nginx_b64
  instance_id="$(tf_output ec2_instance_id)"
  load_domain_config

  log "Instance: ${instance_id}"
  log "Domains: ${API_HOST}, ${IDP_HOST}, ${APP_HOST}, ${ROOT_DOMAIN}, www.${ROOT_DOMAIN}"
  warn "DNS A records must point to $(tf_output ec2_public_ip) before certbot can succeed"

  if ! confirm "Install nginx + certbot on EC2 and issue TLS certificates via SSM?"; then
    warn "Skipped — run '$0 nginx-manual' for manual steps"
    return 0
  fi

  local rendered
  rendered="$(mktemp)"
  render_nginx_conf "${rendered}"
  nginx_b64="$(file_b64 "${rendered}")"
  rm -f "${rendered}"

  run_ssm_command "${instance_id}" "auth-engine-nginx-tls" \
    "set -euo pipefail" \
    "dnf install -y nginx certbot python3-certbot-nginx" \
    "systemctl enable nginx" \
    "mkdir -p /etc/nginx/conf.d" \
    "[ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak || true" \
    "echo '${nginx_b64}' | base64 -d > /etc/nginx/conf.d/authengine.conf" \
    "nginx -t" \
    "systemctl start nginx || true" \
    "systemctl reload nginx" \
    "CERT_EMAIL=\"${CERTBOT_EMAIL:-}\"" \
    "if [ -z \"\${CERT_EMAIL}\" ] && [ -f /opt/authengine/.env ]; then CERT_EMAIL=\$(grep -E '^SUPERADMIN_EMAIL=' /opt/authengine/.env | cut -d= -f2- | tr -d '\"' | head -1); fi" \
    "if [ -z \"\${CERT_EMAIL}\" ] && [ -f /opt/authengine/.env ]; then CERT_EMAIL=\$(grep -E '^EMAIL_SENDER=' /opt/authengine/.env | cut -d= -f2- | tr -d '\"' | head -1); fi" \
    "if [ -z \"\${CERT_EMAIL}\" ]; then CERT_EMAIL=\"noreply@${ROOT_DOMAIN}\"; fi" \
    "echo \"Using certbot email: \${CERT_EMAIL}\" >&2" \
    "if certbot certificates 2>/dev/null | grep -q 'Certificate Name: ${ROOT_DOMAIN}'; then certbot renew --quiet; else certbot --nginx -d ${API_HOST} -d ${IDP_HOST} -d ${APP_HOST} -d ${ROOT_DOMAIN} -d www.${ROOT_DOMAIN} --cert-name ${ROOT_DOMAIN} --non-interactive --agree-tos --email \"\${CERT_EMAIL}\" --redirect --no-eff-email; fi" \
    "nginx -t" \
    "systemctl reload nginx" \
    "curl -fsS -o /dev/null -w 'api:%{http_code}\\n' http://127.0.0.1:8000/api/v1/health || true" \
    "curl -fsS -o /dev/null -w 'nginx-api:%{http_code}\\n' -H 'Host: ${API_HOST}' http://127.0.0.1/api/v1/health || true"

  ok "nginx + TLS configured on EC2"
  log "Verify: curl -I https://${API_HOST}/api/v1/health"
  log "         curl -I https://${APP_HOST}"
  log "         curl -I https://${ROOT_DOMAIN}"
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
  phase "7 — CI/CD (auto-deploy on merge to main)"
  cat <<EOF

Merge to \`main\` in each app repo triggers:

  0-ci (lint) → 1-build-push (Docker Hub :latest) → 4-deploy (EC2 via SSM)

| Repo | 4-deploy does |
|------|----------------|
| auth-engine | pull + recreate \`api\`, run \`auth-engine migrate\` |
| auth-engine-dashboard | pull + recreate \`frontend\` |

One-time GitHub setup (both repos — Settings → Secrets and variables):

Secrets:
  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

Variables:
  EC2_INSTANCE_ID = $(tf_output ec2_instance_id 2>/dev/null || echo 'i-xxxxxxxx')
  AWS_REGION = ap-south-1

IAM user for deploy needs: ssm:SendCommand, ssm:GetCommandInvocation on the EC2 instance.

Manual deploy (same as CI):
  ./deploy/auth-engine-deploy.sh ec2-deploy
  ./deploy/auth-engine-deploy.sh ec2-migrate   # API releases only

First deploy only:
  ./deploy/auth-engine-deploy.sh ec2-seed

EOF
}

cmd_docs() {
  phase "8 — Documentation site (docs.authengine.org)"
  cat <<'EOF'

Docs are served from GitHub Pages — NOT from EC2.

1. auth-engine-infra Settings → Pages → Source: GitHub Actions
2. Run workflow: auth-engine-infra · Deploy docs
3. Custom domain: docs.authengine.org
4. DNS: CNAME docs → <your-github-pages-host>
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
  cmd_ses_dns

  phase "3 — EC2 environment"
  cmd_ec2_env
  if ! confirm "Have you configured /opt/authengine/.env on EC2?"; then
    warn "Configure .env before continuing. Run '$0 ec2-env' for instructions."
    return 0
  fi

  if command -v aws >/dev/null 2>&1 && aws_cli sts get-caller-identity >/dev/null 2>&1; then
    if confirm "Deploy containers on EC2 via SSM?"; then
      cmd_ec2_deploy
    fi
    if confirm "Run database migrations on EC2?"; then
      cmd_ec2_migrate
    fi
    if confirm "Seed roles and super admin on EC2 (first deploy only)?"; then
      cmd_ec2_seed
    fi
  else
    warn "AWS CLI unavailable — run container steps manually on EC2"
  fi

  if command -v aws >/dev/null 2>&1 && aws_cli sts get-caller-identity >/dev/null 2>&1; then
    warn "Ensure DNS A records are live before nginx/certbot"
    if confirm "Install nginx + TLS on EC2 via SSM?"; then
      cmd_nginx
    else
      cmd_nginx_manual
    fi
  else
    cmd_nginx_manual
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
  dns         DNS A/CNAME records for EC2
  ses-dns     SES verification DNS records
  ec2-env     EC2 /opt/authengine/.env setup guide
  ec2-sync-compose  Copy compose + env template to EC2 (SSM)

Application deploy (requires AWS CLI + SSM):
  ec2-deploy  Pull images and start Docker containers on EC2
  ec2-migrate Run auth-engine migrate on EC2
  ec2-seed    Seed roles + super admin on EC2 (after migrate)
  seed        Seed locally via auth-engine-data (local compose only)

TLS + reverse proxy (requires AWS CLI + SSM):
  nginx       Install nginx + certbot on EC2 and issue TLS certs
  nginx-manual  Print manual nginx + certbot steps

Manual checklists:
  oauth       OAuth redirect URI checklist
  cicd        CI/CD release order
  docs        GitHub Pages docs setup

Verification:
  verify      Curl production endpoints

All phases:
  all         Interactive full deployment walk-through

Environment:
  TF_DIR=${TF_DIR}
  TFVARS_FILE=${TFVARS_FILE}
  AWS_PROFILE, AWS_REGION, TF_VAR_db_password
  AUTH_ENGINE_DATA_DIR, GITHUB_ORG, CERTBOT_EMAIL
  SKIP_CONFIRM=1, TF_AUTO_APPROVE=1

Examples:
  $(basename "$0") plan
  $(basename "$0") apply
  $(basename "$0") all
  TF_VAR_db_password=\$(openssl rand -base64 24) $(basename "$0") terraform

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
