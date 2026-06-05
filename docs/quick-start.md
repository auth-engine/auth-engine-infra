---
title: Quick Start
description: Run AuthEngine locally — API, frontend, Postgres, MongoDB, and Redis via Docker Compose.
author: Niranjan
---

# Quick Start

Run the full stack locally from **`auth-engine-infra/compose/`**.

!!! abstract "Steps"
    **1** Configure `.env` → **2** Start Compose → **3** Run migrations → **4** Smoke test

---

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Docker + Docker Compose | Required |
| OpenSSL | Optional — `openssl rand -hex 32` for secrets |

---

## 2. Configure environment

```bash
cd auth-engine-infra/compose
cp env.local.example .env
```

Set `SECRET_KEY` and `JWT_SECRET_KEY` to unique 32+ character values (defaults work for local only).

---

## 3. Start the stack

```bash
docker compose up -d --build
```

| Service | URL |
|---------|-----|
| API | [http://localhost:8000](http://localhost:8000) |
| Swagger | [http://localhost:8000/docs](http://localhost:8000/docs) |
| Frontend | [http://localhost:3000](http://localhost:3000) |

Images build from GitHub (`Q-Niranjan/auth-engine`, `Q-Niranjan/auth-engine-frontend`) unless you override `AUTH_ENGINE_SRC` / `AUTH_ENGINE_FRONTEND_SRC` in `.env`.

---

## 4. Run migrations

```bash
docker exec authengine-api auth-engine migrate
```

On first startup the API seeds RBAC roles and a super admin from `SUPERADMIN_EMAIL` / `SUPERADMIN_PASSWORD` in `.env`.

---

## 5. Smoke test

1. Call `GET /api/v1/health` in Swagger.
2. Log in at [http://localhost:3000/login](http://localhost:3000/login) with super admin credentials.
3. Platform routes (`/platform/*`) need a platform-scoped role; tenant routes need a tenant selected in the dashboard.

---

## 6. OAuth providers (optional)

Set `GOOGLE_*`, `GITHUB_*`, or `MICROSOFT_*` in `.env`. Local redirect URIs:

```text
http://localhost:8000/api/v1/auth/oauth/google/callback
http://localhost:8000/api/v1/auth/oauth/github/callback
http://localhost:8000/api/v1/auth/oauth/microsoft/callback
```

---

## 7. Run without Docker (alternative)

**Backend** — cloned `auth-engine` repo:

```bash
uv sync
auth-engine migrate
auth-engine run
```

**Frontend** — `auth-engine-frontend`:

```bash
cp .env.example .env.local
npm ci && npm run dev
```

```env
NEXT_PUBLIC_API_URL=http://localhost:8000/api/v1
NEXT_PUBLIC_APP_URL=http://localhost:3000
```

---

## Next

| Step | Guide |
|------|-------|
| Understand the system | [Architecture](architecture.md) |
| Deploy to production | [Deployment](deployment.md) |
| OAuth / OIDC integration | [OAuth2 / OIDC Guides](oauth2-oidc-guides.md) |
| REST endpoints | [API Reference](api-reference.md) |
