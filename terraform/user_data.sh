#!/bin/bash
set -euo pipefail

# Start SSM agent first so Session Manager works during bootstrap
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

dnf update -y
dnf install -y docker amazon-ecr-credential-helper curl
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# AL2023 docker package does not include the compose plugin
ARCH="$(uname -m)"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-${ARCH}" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

mkdir -p /opt/authengine
cat >/opt/authengine/README.txt <<'EOF'
AuthEngine API host. Deploy with GitHub Actions (pull from ECR) or manually:

  docker pull <ecr-api-url>:<tag>
  docker run -d --name authengine-api -p 8000:8000 --env-file /opt/authengine/.env <image>

Place environment file at /opt/authengine/.env (POSTGRES_URL, REDIS_URL, MONGODB_URL, secrets).
EOF

echo "ECR API repository: ${ecr_api_url}" >>/opt/authengine/README.txt
