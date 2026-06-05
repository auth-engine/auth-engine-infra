# auth-engine-infra

Infrastructure and **canonical documentation** for the [AuthEngine](https://github.com/auth-engine/auth-engine) platform.

This repository holds AWS Terraform, Docker Compose manifests, and all user-facing guides. Application source code lives in the other two repositories.

| Path | Contents |
|------|----------|
| [`docs/`](docs/) | Platform documentation — built with MkDocs Material, published at [docs.authengine.org](https://docs.authengine.org) |
| [`compose/`](compose/) | `docker-compose.yml` (local) and `docker-compose.prod.yml` (EC2) |
| [`terraform/`](terraform/) | VPC, EC2, RDS, ECR, IAM |

## Documentation

| Guide | Description |
|-------|-------------|
| [Documentation home](docs/index.md) | Platform URLs and where to start |
| [Quick Start](docs/quick-start.md) | Run API, frontend, and databases locally |
| [Deployment Guide](docs/deployment.md) | Hybrid production on AWS (EC2, RDS, Atlas, Upstash) |
| [Architecture](docs/architecture.md) | System design and data flow |
| [API Reference](docs/api-reference.md) | REST endpoints |
| [OAuth2 / OIDC Guides](docs/oauth2-oidc-guides.md) | Social login and OIDC provider |
| [Security Overview](docs/security-overview.md) | Tokens, PBAC, hardening |

## Related repositories

| Repository | Role |
|------------|------|
| [auth-engine](https://github.com/auth-engine/auth-engine) | FastAPI backend — IAM, OIDC, introspection |
| [auth-engine-dashboard](https://github.com/auth-engine/auth-engine-dashboard) | Next.js admin dashboard |
| [auth-engine-infra](https://github.com/auth-engine/auth-engine-infra) | This repo — Terraform, Compose, docs |
