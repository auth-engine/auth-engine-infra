# Deployment Guide

Production uses a **hybrid layout**: AWS for compute (EC2) and PostgreSQL (RDS); **Upstash** for Redis and **MongoDB Atlas** for audit logs. API and dashboard both run as **Docker containers on EC2**, fronted by **nginx** with TLS from Let's Encrypt.

## Platform URLs (production)

| Host | Role | Backend |
|------|------|---------|
| [api.bestcrmhub.com](https://api.bestcrmhub.com) | REST API, Swagger, `/.well-known` | nginx → `localhost:8000` |
| [auth.bestcrmhub.com](https://auth.bestcrmhub.com) | OIDC login UI and IdP endpoints | nginx → `localhost:8000` (same API process) |
| [app.bestcrmhub.com](https://app.bestcrmhub.com) | Admin dashboard | nginx → `localhost:3000` |
| [docs.bestcrmhub.com](https://docs.bestcrmhub.com) | This documentation | GitHub Pages or Cloudflare Pages |

## Hybrid architecture

| Layer | Provider | Notes |
|-------|----------|-------|
| API | EC2 Docker (`authengine-api`) | Image `qniranjan01/authengine` on port 8000 |
| Frontend | EC2 Docker (`authengine-frontend`) | Image `qniranjan01/authengine-frontend` on port 3000 |
| PostgreSQL | AWS RDS (`db.t4g.micro`) | Terraform-managed |
| Redis | Upstash | `rediss://` URL in `/opt/authengine/.env` |
| MongoDB | Atlas M0 | Audit logs; URI must include `/authengine` in path |
| TLS / routing | nginx + certbot on EC2 | Terminates HTTPS for `api`, `auth`, `app` |
| Docs | Static host | `docs/` folder from this repo |

No NAT gateway or ALB in the default Terraform module (cost-optimized).

```mermaid
flowchart LR
    users["Users"]
    nginx["nginx on EC2"]
    api["authengine-api :8000"]
    fe["authengine-frontend :3000"]
    rds["RDS PostgreSQL"]
    redis["Upstash Redis"]
    atlas["MongoDB Atlas"]

    users --> nginx
    nginx --> api
    nginx --> fe
    api --> rds
    api --> redis
    api --> atlas
```

## Terraform

```bash
cd auth-engine-infra/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

### Resources created

- VPC with public subnet
- EC2 instance (`t4g.micro`) + Elastic IP
- RDS PostgreSQL (`db.t4g.micro`)
- ECR repositories: `authengine-api`, `authengine-frontend`
- Security groups (API, RDS, optional SSH)
- IAM role for EC2 (ECR pull, SSM)

Key outputs: `ec2_public_ip`, RDS endpoint (see `outputs.tf`).

| Variable | Default | Purpose |
|----------|---------|---------|
| `aws_region` | `ap-south-1` | Region |
| `project_name` | `authengine` | Resource name prefix |
| `root_domain` | `bestcrmhub.com` | DNS reference |
| `db_password` | (required) | RDS master password |

**GitHub Actions:** `auth-engine-infra · Terraform Plan` → review → `auth-engine-infra · Terraform Apply`

## DNS (Namecheap or any registrar)

Point all application hosts at the EC2 Elastic IP from `terraform output ec2_public_ip`:

| Host | Type | Target |
|------|------|--------|
| `api` | A | EC2 Elastic IP |
| `auth` | A | Same Elastic IP |
| `app` | A | Same Elastic IP |
| `docs` | CNAME | GitHub Pages or Cloudflare Pages |

## EC2 application deployment

Compose files: **`auth-engine-infra/compose/`**

### 1. Environment file

```bash
sudo mkdir -p /opt/authengine
sudo cp compose/env.prod.example /opt/authengine/.env
sudo nano /opt/authengine/.env
sudo chmod 600 /opt/authengine/.env
```

Required variables: `SECRET_KEY`, `JWT_SECRET_KEY`, `POSTGRES_URL`, `MONGODB_URL`, `REDIS_URL`, `APP_URL`, `CORS_ORIGINS`, `SUPERADMIN_*`, `EMAIL_*`. Full list in `compose/env.prod.example`.

| Variable | Production value |
|----------|------------------|
| `APP_URL` | `https://auth.bestcrmhub.com` |
| `CORS_ORIGINS` | `["https://app.bestcrmhub.com"]` |
| `MONGODB_URL` | Must include `/authengine` in the path (not `/?appName=...` only) |
| `REDIS_URL` | `rediss://` (Upstash TLS) |

### 2. Optional OIDC RS256 key

```bash
sudo openssl genrsa -out /opt/authengine/oidc_private.pem 2048
UID=$(docker run --rm qniranjan01/authengine:1.0.0 id -u authengine)
sudo chown $UID:$UID /opt/authengine/oidc_private.pem
sudo chmod 400 /opt/authengine/oidc_private.pem
```

### 3. Start API and frontend

```bash
cd auth-engine-infra/compose
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

Images: Docker Hub `qniranjan01/authengine` and `qniranjan01/authengine-frontend`. Override tag with `AUTHENGINE_IMAGE_TAG` / `AUTHENGINE_FRONTEND_IMAGE_TAG`.

### 4. Migrations

```bash
docker exec authengine-api auth-engine migrate
```

Run once per release after pulling a new API image.

### 5. nginx reverse proxy

Create `/etc/nginx/conf.d/authengine.conf` on EC2:

```nginx
server {
    server_name api.bestcrmhub.com auth.bestcrmhub.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/api.bestcrmhub.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/api.bestcrmhub.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}

server {
    if ($host = auth.bestcrmhub.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot

    if ($host = api.bestcrmhub.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot

    listen 80;
    server_name api.bestcrmhub.com auth.bestcrmhub.com;
    return 404; # managed by Certbot
}

server {
    server_name app.bestcrmhub.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/app.bestcrmhub.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/app.bestcrmhub.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}

server {
    if ($host = app.bestcrmhub.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot

    listen 80;
    server_name app.bestcrmhub.com;
    return 404; # managed by Certbot
}
```

Test and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Issue certificates (if not already done by certbot):

```bash
sudo certbot --nginx -d api.bestcrmhub.com -d auth.bestcrmhub.com
sudo certbot --nginx -d app.bestcrmhub.com
```

Certbot may append the `listen 443 ssl` and HTTP redirect blocks shown above. Verify with:

```bash
sudo cat /etc/nginx/conf.d/authengine.conf
```

## OAuth redirect URIs (production)

Register in each provider console:

```text
https://api.bestcrmhub.com/api/v1/auth/oauth/google/callback
https://api.bestcrmhub.com/api/v1/auth/oauth/github/callback
https://api.bestcrmhub.com/api/v1/auth/oauth/microsoft/callback
```

AuthEngine-as-provider callback for the dashboard:

```text
https://app.bestcrmhub.com/oauth/authengine/callback
```

## Frontend build-time variables

Baked into the Docker image at CI build time:

```env
NEXT_PUBLIC_API_URL=https://api.bestcrmhub.com/api/v1
NEXT_PUBLIC_APP_URL=https://app.bestcrmhub.com
```

Set these in `auth-engine-frontend` GitHub Actions variables or Dockerfile build args before `docker compose pull`.

## CI/CD

All workflows are **manual** (`workflow_dispatch`) unless you enable `on:` triggers in each workflow file.

### auth-engine (backend)

| Workflow | Purpose |
|----------|---------|
| auth-engine · Lint, Typecheck, and Docker Build | CI |
| auth-engine · Create Version Tag | Git tag (e.g. `v1.0.0`) |
| auth-engine · Build and Push Docker Image | Push to Docker Hub |
| auth-engine · Create GitHub Release | Release notes |
| auth-engine · Register Production Deployment | Deployment record |

**Secrets:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

### auth-engine-frontend

| Workflow | Purpose |
|----------|---------|
| auth-engine-frontend · Lint and Build | CI |
| auth-engine-frontend · Create Version Tag | Git tag |
| auth-engine-frontend · Build and Push Docker Image | Push to Docker Hub |
| auth-engine-frontend · Create GitHub Release | Release notes |
| auth-engine-frontend · Register Production Deployment | Deployment record |

### Full release order

1. **auth-engine-infra · Terraform Plan** → **Terraform Apply**
2. Configure Atlas + Upstash; write `/opt/authengine/.env`
3. **auth-engine:** CI → Tag → Build/Push → `docker compose pull` on EC2 → migrate
4. **auth-engine-frontend:** CI → Tag → Build/Push → `docker compose pull` on EC2
5. Register deployments; publish `docs/` to docs.bestcrmhub.com

## Publish documentation

Host the `docs/` folder at **docs.bestcrmhub.com**:

- **GitHub Pages:** branch `main`, folder `/docs`
- **Cloudflare Pages:** same root, custom domain

## Local vs production

| Item | Local (`compose/docker-compose.yml`) | Production |
|------|--------------------------------------|------------|
| `APP_URL` | `http://localhost:3000` | `https://auth.bestcrmhub.com` |
| CORS | `http://localhost:3000` | `https://app.bestcrmhub.com` |
| Databases | Postgres, Mongo, Redis in Compose | RDS + Atlas + Upstash |
| Images | Build from GitHub or pull | Pull from Docker Hub |
| TLS | Optional | Required (nginx + certbot) |

## Related

- [Quick Start](quick-start.md)
- [Architecture](architecture.md)
- [Security Overview](security-overview.md)
