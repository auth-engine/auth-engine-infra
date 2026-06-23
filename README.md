# auth-engine-infra

Infrastructure and deployment tooling for **AuthEngine** — Docker Compose for development, Helm chart for Kubernetes production, AWS Terraform for EC2, and automated deploy scripts.

Single-node K3s + Rancher runs the full production stack: API, dashboard, Postgres, MongoDB, Redis, Ingress, and cert-manager.

## Layout

| Path | Purpose |
|------|---------|
| [`compose/`](compose/) | Docker Compose — local dev full stack |
| [`helm/authengine/`](helm/authengine/) | Helm chart — production Kubernetes |
| [`terraform/`](terraform/) | AWS EC2 + VPC + Elastic IP |
| [`scripts/`](scripts/) | `deploy-local-vm.sh` · `deploy-aws.sh` |

## Development

### 1. Local

Run [auth-engine](https://github.com/auth-engine/auth-engine) and [auth-engine-dashboard](https://github.com/auth-engine/auth-engine-dashboard) on your host. Use each repo's `.env.example` and seed via [auth-engine-data](https://github.com/auth-engine/auth-engine-data).

### 2. Compose

```bash
cd compose
cp env.local.example .env
docker compose up -d
docker exec authengine-api auth-engine migrate
```

Seed: [auth-engine-data README](https://github.com/auth-engine/auth-engine-data).

## Production

| Path | Script |
|------|--------|
| Local VM + Cloudflare Tunnel | `./scripts/deploy-local-vm.sh all` |
| AWS EC2 or any cloud VM | `./scripts/deploy-aws.sh all` |

Min specs: **4 vCPU · 8 GB RAM · 40 GB disk** (lab) · **16 GB RAM** recommended for production.

## Documentation

| Guide | Link |
|-------|------|
| Quick Start | [docs.authengine.org/quick-start](https://docs.authengine.org/quick-start/) |
| Deployment | [docs.authengine.org/deployment](https://docs.authengine.org/deployment/) |
| Architecture | [docs.authengine.org/architecture](https://docs.authengine.org/architecture/) |
| Security | [docs.authengine.org/security-overview](https://docs.authengine.org/security-overview/) |

## Related repositories

[auth-engine](https://github.com/auth-engine/auth-engine) · [auth-engine-dashboard](https://github.com/auth-engine/auth-engine-dashboard) · [auth-engine-data](https://github.com/auth-engine/auth-engine-data) · [auth-engine-docs](https://github.com/auth-engine/auth-engine-docs)
