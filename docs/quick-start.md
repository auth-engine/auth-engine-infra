# Quick Start

Run the full stack locally: API, frontend, Postgres, MongoDB, and Redis — from **`auth-engine-infra/compose/`**.

## Prerequisites

- Docker and Docker Compose
- `openssl rand -hex 32` for secrets (optional; defaults work for local)

## 1. Configure environment

```bash
cd auth-engine-infra/compose
cp env.local.example .env
```

Edit `.env` if needed — at minimum set `SECRET_KEY` and `JWT_SECRET_KEY` to unique 32+ character values.

## 2. Start the stack

```bash
docker compose up -d --build
```

This starts:

| Service | URL |
|---------|-----|
| API | [http://localhost:8000](http://localhost:8000) |
| Swagger | [http://localhost:8000/docs](http://localhost:8000/docs) |
| Frontend | [http://localhost:3000](http://localhost:3000) |

Images are built from GitHub (`Q-Niranjan/auth-engine`, `Q-Niranjan/auth-engine-frontend`) unless you change `AUTH_ENGINE_SRC` / `AUTH_ENGINE_FRONTEND_SRC` in `.env`.

## 3. Migrations

```bash
docker exec authengine-api auth-engine migrate
```

On first startup the API seeds RBAC roles and a super admin from `SUPERADMIN_EMAIL` / `SUPERADMIN_PASSWORD` in `.env`.

## 4. Smoke test

1. Call `GET /api/v1/health` in Swagger.
2. Log in at [http://localhost:3000/login](http://localhost:3000/login) with super admin credentials.
3. Platform routes (`/platform/*`) require a platform-scoped role; tenant routes require selecting a tenant in the dashboard.

## OAuth providers (optional)

Set `GOOGLE_*`, `GITHUB_*`, or `MICROSOFT_*` in `.env`. Local redirect URIs:

```text
http://localhost:8000/api/v1/auth/oauth/google/callback
http://localhost:8000/api/v1/auth/oauth/github/callback
http://localhost:8000/api/v1/auth/oauth/microsoft/callback
```

## Run without Docker (alternative)

**Backend** — from a cloned `auth-engine` repo:

```bash
uv sync
auth-engine migrate
auth-engine run
```

**Frontend** — from `auth-engine-frontend`:

```bash
cp .env.example .env.local
npm ci && npm run dev
```

```env
NEXT_PUBLIC_API_URL=http://localhost:8000/api/v1
NEXT_PUBLIC_APP_URL=http://localhost:3000
```

## Next steps

- [Deployment Guide](deployment.md) — hybrid production on AWS
- [OAuth2 / OIDC Guides](oauth2-oidc-guides.md)
- [API Reference](api-reference.md)
