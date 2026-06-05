# AuthEngine Documentation

Canonical documentation for the AuthEngine platform.

**Published at:** [docs.bestcrmhub.com](https://docs.bestcrmhub.com)

## Production URLs

| Host | Role |
|------|------|
| [api.bestcrmhub.com](https://api.bestcrmhub.com) | REST API · [Swagger](https://api.bestcrmhub.com/docs) |
| [auth.bestcrmhub.com](https://auth.bestcrmhub.com) | OIDC Identity Provider (login, consent) |
| [app.bestcrmhub.com](https://app.bestcrmhub.com) | Admin dashboard |
| [docs.bestcrmhub.com](https://docs.bestcrmhub.com) | Documentation |

Local development: API `http://localhost:8000`, frontend `http://localhost:3000`.

## Guides

| Guide | Description |
|-------|-------------|
| [Quick Start](quick-start.md) | Local stack via Docker Compose |
| [Deployment Guide](deployment.md) | Hybrid AWS deployment (EC2, RDS, Atlas, Upstash) |
| [Architecture](architecture.md) | System design and data stores |
| [API Reference](api-reference.md) | REST endpoints and auth headers |
| [OAuth2 / OIDC Guides](oauth2-oidc-guides.md) | Social login and OIDC provider |
| [Security Overview](security-overview.md) | Tokens, sessions, PBAC, hardening |

## Repositories

| Repository | Purpose |
|------------|---------|
| [auth-engine](https://github.com/Q-Niranjan/auth-engine) | FastAPI backend |
| [auth-engine-frontend](https://github.com/Q-Niranjan/auth-engine-frontend) | Next.js dashboard |
| [auth-engine-infra](https://github.com/Q-Niranjan/auth-engine-infra) | Terraform, Docker Compose, this documentation |

> Docs live in **auth-engine-infra**, not the backend repo.  
> Example: `https://github.com/Q-Niranjan/auth-engine-infra/blob/main/docs/architecture.md`

## Quick links

- OIDC discovery: `GET https://api.bestcrmhub.com/.well-known/openid-configuration`
- JWKS: `GET https://api.bestcrmhub.com/.well-known/jwks.json`
- Token introspect: `POST https://api.bestcrmhub.com/api/v1/platform/service-keys/introspect` (header `X-API-Key`)
