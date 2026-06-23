# auth-engine-infra

Infrastructure for **AuthEngine** — AWS Terraform (EC2), Helm chart (K3s/Rancher), and Docker Compose for local development.

**Documentation:** [auth-engine-docs](https://github.com/auth-engine/auth-engine-docs) · published at [docs.authengine.org](https://docs.authengine.org)

| Guide | Link |
|-------|------|
| Quick Start | [quick-start.md](https://docs.authengine.org/quick-start/) |
| OAuth2 / OIDC | [oauth2-oidc-guides.md](https://docs.authengine.org/oauth2-oidc-guides/) |
| API Reference | [api-reference.md](https://docs.authengine.org/api-reference/) |
| Architecture | [architecture.md](https://docs.authengine.org/architecture/) |
| Deployment | [deployment.md](https://docs.authengine.org/deployment/) |
| Security | [security-overview.md](https://docs.authengine.org/security-overview/) |

## What this repository is

| Path | Contents |
|------|----------|
| [`terraform/`](terraform/) | AWS EC2 + VPC + Elastic IP (K3s/Rancher node) |
| [`helm/authengine/`](helm/authengine/) | Production Helm chart — API, dashboard, Postgres, MongoDB, Redis, Ingress |
| [`compose/`](compose/) | `docker-compose.yml` for **local development** only |
| [`deploy/`](deploy/) | `auth-engine-deploy.sh` — Terraform, K3s, Helm, seed, verify |

Application source code and platform documentation live in the other repositories.

## Production (K3s + Rancher + Helm)

1. **Terraform** — provision EC2 (`t4g.xlarge` recommended)
2. **DNS** — point `api`, `auth`, `app`, `rancher` to the Elastic IP
3. **K3s + Rancher** — install on EC2 (see [deployment guide](https://docs.authengine.org/deployment/))
4. **Helm** — `helm install authengine helm/authengine` with production secrets
5. **Seed** — enable `seed.enabled` in Helm values or run `auth-engine-data all`
6. **CI/CD** — merge to `main` builds Docker images; redeploy workloads in Rancher

```bash
./deploy/auth-engine-deploy.sh all    # interactive walk-through
```

## Local development (Docker Compose)

```bash
cd compose
cp env.local.example .env
docker compose up -d
docker exec authengine-api auth-engine migrate
```

After migrations, seed from **[auth-engine-data](https://github.com/auth-engine/auth-engine-data)**:

```bash
cd ../../auth-engine-data
uv sync && cp .env.example .env.local
uv run auth-engine-data all
```

## Production URLs

| Host | Role |
|------|------|
| [api.authengine.org](https://api.authengine.org) | API + Swagger |
| [auth.authengine.org](https://auth.authengine.org) | OIDC / login UI |
| [app.authengine.org](https://app.authengine.org) | Admin dashboard |
| [rancher.authengine.org](https://rancher.authengine.org) | Cluster management |
| [docs.authengine.org](https://docs.authengine.org) | Documentation |

## Contributing

See [Contributing](https://docs.authengine.org/contributing/) or [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues per [Security Policy](https://docs.authengine.org/security-policy/) — not via public issues.

## Related repositories

| Repository | Role |
|------------|------|
| [auth-engine](https://github.com/auth-engine/auth-engine) | FastAPI backend — IAM, OIDC, introspection |
| [auth-engine-dashboard](https://github.com/auth-engine/auth-engine-dashboard) | Next.js admin dashboard |
| [auth-engine-data](https://github.com/auth-engine/auth-engine-data) | Roles, permissions & super-admin seeding |
| [auth-engine-docs](https://github.com/auth-engine/auth-engine-docs) | Platform documentation |
| [.github](https://github.com/auth-engine/.github) | Org profile, contributing & security policy |
