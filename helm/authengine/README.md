# authengine Helm chart

Deploys the full AuthEngine production stack on Kubernetes (K3s/Rancher):

- **api** — FastAPI (`qniranjan01/authengine`)
- **dashboard** — Next.js (`qniranjan01/authengine-dashboard`)
- **postgres**, **mongodb**, **redis** — in-cluster StatefulSets
- **Ingress** — `api`, `auth`, and `app` hosts with cert-manager TLS
- **migrate Job** — Helm hook on install/upgrade (`auth-engine migrate`)
- **seed Job** — regular Kubernetes Job (visible in Rancher); runs on install, or on upgrade when `seed.runOnUpgrade: true`

## Install

The chart defaults to `ingress.className: traefik`, which is the recommended ingress class for a standard K3s setup.

```bash
cd auth-engine-infra/helm/authengine
cp values.yaml prod-values.yaml
# Edit prod-values.yaml — set secrets.* and seed.* (do not commit)

helm install authengine . \
  --namespace authengine \
  --create-namespace \
  -f prod-values.yaml
```

## Required secret overrides

| Value | Purpose |
|-------|---------|
| `secrets.postgresPassword` | Postgres admin password |
| `secrets.mongoPassword` | MongoDB root password |
| `secrets.redisPassword` | Redis password |
| `secrets.secretKey` | API `SECRET_KEY` (32+ chars) |
| `secrets.jwtSecretKey` | API `JWT_SECRET_KEY` |
| `secrets.resendApiKey` | Resend email API key (recommended) |
| `seed.superadminEmail` / `superadminPassword` | First super admin (when `seed.enabled: true`) |

## Upgrade / redeploy after new Docker image

```bash
helm upgrade authengine . -n authengine -f prod-values.yaml
# Or in Rancher UI: Workloads → api / dashboard → Redeploy
kubectl rollout restart deployment/api -n authengine
kubectl exec -n authengine deployment/api -- auth-engine migrate
```

## Re-run database seed (platform tenant + super admin)

Seed Jobs are normal Kubernetes Jobs (not hidden Helm hooks). On upgrade, set `seed.runOnUpgrade: true`:

```bash
helm upgrade authengine . -n authengine -f prod-values.yaml --set seed.runOnUpgrade=true
kubectl get jobs -n authengine
kubectl logs -n authengine job/authengine-seed-<revision> -f
```

In Rancher: **Workloads → Jobs** — look for `authengine-seed-*` and `authengine-migrate`.

Full guide: [docs.authengine.org/deployment](https://docs.authengine.org/deployment/)
