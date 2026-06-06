# AuthEngine Documentation (source)

Published at **[docs.authengine.org](https://docs.authengine.org)** — built with **MkDocs Material**.

Navigation is **mandatory** — all pages are defined in [`mkdocs.yml`](../mkdocs.yml) `nav:` (no auto-discovery).

## Reading order

1. [index.md](index.md) — home and navigation
2. [quick-start.md](quick-start.md) — local Docker Compose
3. [architecture.md](architecture.md) — system design
4. [deployment.md](deployment.md) — production (phases 1–9)
5. [security-overview.md](security-overview.md) — hardening
6. [api-reference.md](api-reference.md) — REST API
7. [oauth2-oidc-guides.md](oauth2-oidc-guides.md) — OAuth / OIDC
8. [contributing.md](contributing.md) — Open source contributions
9. [security-policy.md](security-policy.md) — Vulnerability reporting
10. [about-author.md](about-author.md) — About AuthEngine

## Local preview

```bash
pip install -r requirements-docs.txt
mkdocs serve
```

Open `http://127.0.0.1:8000`.
