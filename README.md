# auth-engine-infra

Infrastructure for **AuthEngine** — AWS Terraform and Docker Compose manifests.

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

Owns `terraform/` (VPC, EC2, RDS, ECR, IAM, SES) and `compose/` (local and production Docker Compose stacks). Application source code and platform documentation live in the other repositories.

| Path | Contents |
|------|----------|
| [`terraform/`](terraform/) | AWS infrastructure — VPC, EC2, RDS, ECR, IAM, SES |
| [`compose/`](compose/) | `docker-compose.yml` (local) and `docker-compose.prod.yml` (EC2) |

## Quick reference

```bash
# Local stack
cd compose
cp env.local.example .env
docker compose pull
docker compose up -d

# AWS infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

## Production

| Host | Role |
|------|------|
| [api.authengine.org](https://api.authengine.org) | API + Swagger |
| [auth.authengine.org](https://auth.authengine.org) | OIDC / login UI |
| [app.authengine.org](https://app.authengine.org) | Admin dashboard |
| [docs.authengine.org](https://docs.authengine.org) | Documentation |

## Docker

This repository owns the Compose manifests in [`compose/`](compose/).

```bash
cd compose
cp env.local.example .env
docker compose pull
docker compose up -d
docker exec authengine-api auth-engine migrate
```

After migrations, seed roles and the super admin from the host with **[auth-engine-data](https://github.com/auth-engine/auth-engine-data)**:

```bash
cd ../../auth-engine-data
uv sync && cp .env.example .env.local
uv run auth-engine-data all
```

Production overlay: `docker-compose.prod.yml` with pre-built images. Full guide: [Deployment](https://docs.authengine.org/deployment/).

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
