---
title: Architecture
description: System design — components, data stores, request lifecycle, and multi-tenancy.
author: Niranjan
---

# Architecture

AuthEngine is a **single FastAPI service**: one process owns IAM, tenancy, OIDC, and audit. The dashboard is a separate Next.js app. External services validate tokens via introspection.

!!! abstract "Contents"
    **1** System diagram → **2** Components → **3** Backend layers → **4** Design principles → **5** Request lifecycle → **6** Data stores → **7** Multi-tenancy → **8** Code layout → **9** Frontend → **10** Production topology

---

## 1. High-level system diagram

```mermaid
flowchart TB
    subgraph clients ["Clients"]
        browser["Browser and dashboard"]
        rp["Relying party apps"]
        backend_svc["Backend services"]
    end

    subgraph aws_infra ["AWS EC2 hybrid"]
        nginx["nginx TLS"]
        api_ctr["API container :8000"]
        fe_ctr["Frontend container :3000"]
        rds["RDS PostgreSQL"]
    end

    subgraph managed ["Managed services"]
        upstash["Upstash Redis"]
        atlas["Atlas MongoDB"]
        hub["Docker Hub images"]
    end

    browser --> nginx
    rp --> nginx
    backend_svc --> nginx
    nginx --> api_ctr
    nginx --> fe_ctr
    api_ctr --> rds
    api_ctr --> upstash
    api_ctr --> atlas
    hub --> api_ctr
    hub --> fe_ctr
```

## 2. Component responsibilities

| Component | Repository | Responsibility |
|-----------|------------|----------------|
| API service | `auth-engine` | Auth, RBAC, OIDC, tenant config, introspection |
| Dashboard | `auth-engine-dashboard` | Platform/tenant admin UI, user self-service |
| Infrastructure | `auth-engine-infra` | Terraform, Docker Compose, VPC, EC2, RDS, documentation |

## 3. Backend internal architecture

```mermaid
flowchart TB
    subgraph api_layer ["API layer FastAPI"]
        public_routes["auth, oidc, me"]
        platform_routes["platform"]
        tenant_routes["tenants"]
        well_known["well-known"]
    end

    subgraph deps_layer ["Dependencies"]
        auth_dep["get_current_user"]
        rbac_dep["require_permission"]
        db_dep["get_db and get_redis"]
    end

    subgraph svc_layer ["Service layer"]
        auth_svc["AuthService"]
        oauth_svc["OAuthService"]
        intro_svc["IntrospectService"]
        session_svc["SessionService"]
        tenant_svc["TenantService"]
        audit_svc["AuditService"]
    end

    subgraph strategy_layer ["Auth strategies"]
        email_pw["EmailPassword"]
        oauth_providers["Google, GitHub, Microsoft"]
        magic_link["MagicLink"]
        totp_mfa["TOTP MFA"]
        webauthn["WebAuthn"]
    end

    subgraph repo_layer ["Repositories"]
        pg_repo["Postgres repos"]
        mongo_repo["Mongo audit"]
        redis_repo["Redis sessions"]
    end

    pg_db["PostgreSQL"]
    mongo_db["MongoDB audit_logs"]
    redis_db["Redis"]

    public_routes --> auth_dep
    platform_routes --> rbac_dep
    tenant_routes --> rbac_dep
    auth_dep --> auth_svc
    rbac_dep --> tenant_svc
    auth_svc --> email_pw
    auth_svc --> magic_link
    auth_svc --> webauthn
    oauth_svc --> oauth_providers
    tenant_svc --> totp_mfa
    auth_svc --> pg_repo
    oauth_svc --> pg_repo
    intro_svc --> pg_repo
    session_svc --> redis_repo
    audit_svc --> mongo_repo

    pg_repo --> pg_db
    mongo_repo --> mongo_db
    redis_repo --> redis_db
```

## 4. Design principles

**Strategy pattern** — Each auth method implements `BaseAuthStrategy` (`authenticate`, `validate`). New providers do not modify existing strategies.

**PBAC with level hierarchy** — Endpoints check permission strings (e.g. `tenant.users.manage`), not role names. Role `level` (0–100) blocks assigning equal-or-higher roles.

**Repository pattern** — Services contain business logic; repositories own SQLAlchemy, Motor, and Redis access.

## 5. Request lifecycle

```mermaid
sequenceDiagram
    participant Client
    participant Router as FastAPI Router
    participant DI as Dependencies
    participant EP as Endpoint
    participant Svc as Service
    participant Repo as Repository
    participant Store as Data stores

    Client->>Router: HTTP request
    Router->>DI: resolve DB user permissions
    DI->>EP: injected context
    EP->>Svc: business call
    Svc->>Repo: data access
    Repo->>Store: query and cache
    Store-->>Client: JSON response
```

Audit writes to MongoDB are fire-and-forget from the caller’s perspective.

## 6. Data stores

| Store | Technology | Contents |
|-------|------------|----------|
| PostgreSQL | RDS (prod) / Compose (local) | Users, roles, permissions, tenants, OAuth accounts, OIDC clients, API keys, configs |
| Redis | Upstash (prod) | Sessions, token blacklist, OAuth state, magic-link JTIs, MFA pending, rate limits, WebAuthn challenges |
| MongoDB | Atlas (prod) | Append-only `audit_logs` |

### Redis key patterns

| Pattern | Purpose |
|---------|---------|
| `session:{user_id}:{session_id}` | Active sessions |
| `blacklist:{jti}` | Revoked access tokens |
| `oauth:state:{token}` | OAuth CSRF state (~10 min) |
| `magic:jti:{jti}` | One-time magic links (~15 min) |
| `mfa:pending:{user_id}` | Post-login MFA step (~5 min) |
| `ratelimit:{ip}:{minute}` | Per-IP rate limiting |
| `webauthn:reg:{user_id}` | Registration challenge |
| `webauthn:auth:{challenge}` | Authentication challenge |

## 7. Multi-tenancy model

```mermaid
erDiagram
    USER ||--o{ USER_ROLE : has
    ROLE ||--o{ USER_ROLE : assigned
    TENANT ||--o{ USER_ROLE : scopes
    ROLE ||--o{ ROLE_PERMISSION : grants
    PERMISSION ||--o{ ROLE_PERMISSION : includes

    USER {
        uuid id
        string email
        string auth_strategies
    }
    TENANT {
        uuid id
        string name
    }
    USER_ROLE {
        uuid user_id
        uuid role_id
        uuid tenant_id
    }
    ROLE {
        uuid id
        string name
        int level
    }
    PERMISSION {
        uuid id
        string name
    }
    ROLE_PERMISSION {
        uuid role_id
        uuid permission_id
    }
```

A user can hold different roles in different tenants via multiple `UserRole` rows. Tenant-scoped API paths include `{tenant_id}`; guards evaluate permissions in that tenant context.

## 8. API module layout (`auth_engine`)

```
src/auth_engine/
├── api/v1/          # Routers: public, platform, tenants, oidc, me, system
├── auth_strategies/ # email_password, oauth/*, magic_link, totp, webauthn
├── core/            # config, security, postgres, redis, mongodb, oidc_crypto
├── models/          # SQLAlchemy ORM
├── repositories/    # Data access
├── schemas/         # Pydantic request/response
├── services/        # Business logic
├── templates/       # OIDC login, email, SMS
└── main.py          # App entry, CORS, lifespan, /.well-known mount
```

## 9. Frontend architecture

- **Framework:** Next.js App Router, React, Zustand (`auth-store`)
- **HTTP:** Axios `apiClient` with Bearer token, `X-Tenant-Id`, automatic refresh on 401
- **Layouts:** `(auth)` for login flows; `(dashboard)/platform` and `(dashboard)/tenant` for admin
- **Security UI:** MFA and passkey management under `/me/security`

## 10. Production topology

Hybrid deployment on a single EC2 instance:

- **nginx** terminates TLS for `api.authengine.org`, `auth.authengine.org`, and `app.authengine.org`
- **API** and **frontend** run as Docker containers (`compose/docker-compose.prod.yml`)
- **RDS**, **Upstash**, and **Atlas** are external managed services

See [Deployment Guide](deployment.md) for DNS, `.env`, CI/CD, and nginx setup.

## Next

| Step | Guide |
|------|-------|
| Deploy this layout | [Deployment](deployment.md) |
| REST endpoints | [API Reference](api-reference.md) |
| Security controls | [Security Overview](security-overview.md) |
| OAuth / OIDC | [OAuth2 / OIDC Guides](oauth2-oidc-guides.md) |
