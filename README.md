# auth-engine-infra

Infrastructure for the [AuthEngine](https://github.com/auth-engine/auth-engine)
platform: AWS Terraform and Docker Compose manifests. Application source code
and documentation live in the other repositories.

| Path | Contents |
|------|----------|
| [`terraform/`](terraform/) | AWS infrastructure — VPC, EC2, RDS, ECR, IAM, SES |
| [`compose/`](compose/) | `docker-compose.yml` (local) and `docker-compose.prod.yml` (EC2) |

## Quick reference

```bash
# Local stack
cd compose
cp env.local.example .env
docker compose up -d

# AWS infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

## Related repositories

| Repository | Role |
|------------|------|
| [auth-engine](https://github.com/auth-engine/auth-engine) | FastAPI backend — IAM, OIDC, introspection |
| [auth-engine-dashboard](https://github.com/auth-engine/auth-engine-dashboard) | Next.js admin dashboard |
| [auth-engine-data](https://github.com/auth-engine/auth-engine-data) | Roles, permissions & super-admin seeding |
| [auth-engine-docs](https://github.com/auth-engine/auth-engine-docs) | Platform documentation — [docs.authengine.org](https://docs.authengine.org) |
