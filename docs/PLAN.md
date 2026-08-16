# PLAN.md

Live working plan for `clients-infra`. Convention: strike/check off finished items, move detail
into `README.md`/`CLAUDE.md` once it's how the repo actually works, keep gap IDs (`G1`…`G21`) in
sync with `docs/ARCHITECTURE_IMPROVEMENTS.md`. Full rationale and code snippets for each item live
in `docs/IMPLEMENTATION_PLAN.md` — this file is the actionable checklist derived from it.

---

## Current status (as of 2026-08-15)

- All platform stacks deployed and healthy in `eu-west-1` (account `997979358457`):
  `camedina-dev-network`, `camedina-dev-ecr`, `camedina-dev-github-oidc`, `camedina-dev-ecs-cluster`,
  `camedina-dev-alb`, `camedina-dev-rds`. Both service stacks (`camedina-dev-clients-service`,
  `camedina-dev-clients-front`) are also deployed.
- Both ECS services are currently scaled to **desired-count 0** (cost-saving, "apaga todo"). Fixed
  infra cost while scaled to 0: NAT ~$0.048/hr + ALB ~$0.0252/hr + RDS t3.micro ~$0.02/hr ≈
  $0.093/hr — no Fargate compute cost.
- **Open bug, next-session priority:** user creation isn't working via the front end
  ("no está funcionando la creación de usuario"). Not yet reproduced/investigated — deferred across
  three sessions (08-13, 08-13 follow-up, 08-15).
- **Also pending:** `application.properties` datasource fix in the `clients-service` repo (reading
  `DB_HOST`/`DB_PORT`/etc from env vars) is still local-only there — needs commit + push in that repo.
- To resume: scale services back to desired-count 1 (`make deploy-all-services` or
  `aws ecs update-service --desired-count 1` for both services) before debugging. Don't re-run
  `deploy-network`/`deploy-ecr`/`deploy-github-oidc` — already up to date.
- App repo locations: `~/IdeaProjects/clients-service` (Spring Boot; older duplicate at
  `~/IdeaProjects/camedina-clients-service`) and `~/WebstormProjects/clients-front` (Next.js).
- CI note: if `Deploy Infra` fails with an OIDC/assume-role error, check whether
  `camedina-dev-github-oidc` was mid-redeploy around the same time — it's a transient race
  (`gh run rerun <run-id>` fixes it), not a config bug. See 2026-08-13 incident.

---

## Infrastructure plan (extracted from `docs/IMPLEMENTATION_PLAN.md`)

Conventions inherited by every task below: one template per stack, cross-stack wiring only through
`Fn::ImportValue` on `${Environment}-*` exports, parameter values in `config/<env>.env`, tags
applied once via the Makefile's `TAGS`, `make validate` before any deploy, service stacks deployed
by hand (never by `deploy-infra.yml`) to avoid racing the app repos' `force-new-deployment`.

### Phase 0 — Correctness fixes (~1 day)

- [ ] **0.1** Inject `SECURITY_JWT_SECRET` into `clients-service` (G1, critical) — add a
      `JwtSecret` `AWS::SecretsManager::Secret` (mirrors `SessionSecret` in
      `service-clients-front.yaml`), add to `TaskExecutionRole`'s secrets policy, wire into the
      container's `Secrets`, add `SPRING_PROFILES_ACTIVE`. **Rotating logs out every user once** —
      do before real users exist.
- [ ] **0.2** ECS container health checks / readiness probes (G5) — `HealthCheck` block on both
      `service-clients-service.yaml` (`/actuator/health/readiness`) and
      `service-clients-front.yaml` (`/api/health`, new route). Sequence with backend/frontend
      health-endpoint work, or point at `/actuator/health` and `/` in the interim.
- [ ] **0.3** Deployment circuit breaker with rollback (G8) — `DeploymentConfiguration` +
      `DeploymentCircuitBreaker: {Enable: true, Rollback: true}` on both `AWS::ECS::Service`
      resources.
- [ ] **0.4** Enable ECS Exec (G21) — `EnableExecuteCommand: true` on both services + `TaskRole`
      SSM messages policy, enabling `aws ecs execute-command ... --interactive --command /bin/sh`.
- [ ] **0.5** Enable Container Insights (G11) — `ecs-cluster.yaml` `ClusterSettings` →
      `containerInsights: enhanced`. Small ongoing cost; prerequisite for Phase 3's queue-depth
      autoscaling metric math and the Phase 4 dashboard.

**Exit criteria:** backend token signed with a real secret; a deliberately broken image rolls back
automatically; `aws ecs execute-command` opens a shell in a running task.

### Phase 1 — Edge: TLS, custom domain, CloudFront (~2 days)

Implements ADR-001. Closes G2, G3, part of G14.

- [ ] **1.1** Register/transfer a domain into Route 53 (long pole — start first). New
      `config/dev.env`: `DOMAIN_NAME`, `HOSTED_ZONE_ID`, `APP_SUBDOMAIN`.
- [ ] **1.2** New stack `templates/dns-certificate.yaml` — ACM cert for
      `${AppSubdomain}.${DomainName}` in **us-east-1** (CloudFront requirement — separate
      `make deploy-certificate-edge` target with explicit `--region`), plus a regional
      `eu-west-1` cert for the ALB HTTPS listener. `ValidationMethod: DNS` with
      `DomainValidationOptions.HostedZoneId`. Exports: edge cert ARN, regional cert ARN, hosted
      zone ID.
- [ ] **1.3** `templates/alb.yaml` — HTTPS listener (443, cert from regional ARN,
      `ELBSecurityPolicy-TLS13-1-2-2021-06`); :80 listener default action becomes a 301 redirect
      to HTTPS; **origin lock** via `OriginVerifySecret` + a 403-unless-header rule fed by
      CloudFront's `OriginCustomHeaders`; narrow `AlbSecurityGroup` ingress to the
      `com.amazonaws.global.cloudfront.origin-facing` managed prefix list.
- [ ] **1.4** New stack `templates/cdn.yaml` — `AWS::CloudFront::Distribution`: ALB origin over
      HTTPS with the verify header; default behavior `CachingDisabled`/`AllViewer` (SSR + cookies
      must reach origin intact); `/_next/static/*` (+`/favicon.ico`,`/public/*`) behavior on
      `CachingOptimized`; alias + viewer cert from the us-east-1 ACM ARN; response headers policy
      (HSTS, `X-Content-Type-Options`, `Referrer-Policy`, starter CSP); Route 53 alias record.
      Exports: CDN domain name, distribution ID. Distributions take 5–15 min to deploy.
- [ ] **1.5** `templates/waf.yaml` rate limiting (G14) — `RateLimitPerIp` rule (2000/5-min) plus a
      tighter scoped-down rule (limit 100) on `/login`/`/signup` paths. Stays regional on the ALB;
      a second CLOUDFRONT-scope WebACL is optional/skippable.
- [ ] **1.6** Makefile: `deploy-certificate-edge` (us-east-1!), `deploy-dns-certificate`,
      `deploy-cdn`; add to `deploy-platform` and `deploy-infra.yml` trigger paths. Order:
      dns-certificate → alb → waf → cdn.

**Exit criteria:** `https://app.<domain>` serves the app; `http://` redirects; direct ALB DNS
returns 403; `Secure` cookies survive login; `/_next/static/*` shows `x-cache: Hit from cloudfront`
on repeat.

### Phase 3 — Event backbone (~2 days infra, ~3 days app)

Implements ADR-002/003. Infra side only; producer/consumer app code is in the backend plan.

- [ ] **3.1** New stack `templates/messaging.yaml` — `DomainEventsTopic` SNS topic (separate from
      the `alerts` topic). Per consumer (`notifications`, `jobs` to start): `<Name>Queue` (60s
      visibility timeout, 14d retention, redrive to DLQ after 5 receives), `<Name>Dlq` (14d
      retention), `<Name>Subscription` (SQS protocol, raw delivery, `FilterPolicy` on `eventType`),
      `<Name>QueuePolicy` (allow `sns.amazonaws.com` send with `aws:SourceArn` condition — easy to
      forget). Alarms per queue on DLQ depth > 0 and oldest-message age > 300s, to the alerts
      topic. Exports: topic ARN, per-queue URL/ARN, per-DLQ ARN.
- [ ] **3.2** `service-clients-service.yaml` producer permissions (G13) — `TaskRole` `sns:Publish`
      policy scoped to the domain-events topic ARN; add `DOMAIN_EVENTS_TOPIC_ARN` to container env.
- [ ] **3.3** New stack `templates/service-clients-worker.yaml` — same ECR image as
      clients-service, `SPRING_PROFILES_ACTIVE=worker`; SQS receive/delete/visibility perms on
      both queues; RDS SG ingress scoped to the worker's task SG; **no** ALB/Cloud Map
      registrations; queue-depth target-tracking autoscaling (`backlogPerTask` metric math,
      `TargetValue: 20`, requires Container Insights from 0.5). `MinCapacity: 1` recommended over
      0 (avoids cold start on first message).
- [ ] **3.4** Makefile + `config/dev.env`: `CLIENTS_WORKER_*` vars; `deploy-messaging` into
      `deploy-platform`; `deploy-service-clients-worker` into `deploy-all-services` (hand-deployed,
      same race reasoning as the other two service stacks).

**Exit criteria:** test SNS publish lands in both queues; killing the worker triggers the
oldest-message-age alarm; an always-throwing handler DLQs after 5 attempts and fires the DLQ alarm.

### Phase 4 — Observability (~2 days infra)

- [ ] **4.1** ADOT/X-Ray sidecar on all three task definitions (`aws-otel-collector` container),
      `AWSXRayDaemonWriteAccess` on each `TaskRole`, bump task memory to 1024 (sidecar + JVM in 512
      is tight). App-side instrumentation is in the per-repo plans.
- [ ] **4.2** New stack `templates/dashboard.yaml` — one `AWS::CloudWatch::Dashboard` per
      environment, JSON defined in-template: Edge (CloudFront + ALB metrics), Compute (per-service
      CPU/mem/task count/deployment state), Data (RDS metrics), Async (per-queue depth/age,
      DLQ depth).
- [ ] **4.3** Metric filter on backend log group for `level=ERROR` → custom metric → alarm on the
      alerts topic, so app errors reach the same email path as infra alarms. (Log retention
      already fine at 14 days.)

### Phase 5 — Public API via API Gateway (~2 days)

Fronts the **API**, not the SSR app (see ADR-001). Skip unless the portfolio story needs it —
significant cost for a capability nothing currently consumes.

- [ ] **5.1** New stack `templates/api-gateway.yaml` — internal ALB (private subnets) targeting
      `clients-service` (VPC Links need an ALB/NLB target, not Cloud Map); `VpcLink` in private
      subnets; HTTP API with throttling + access logging; `HTTP_PROXY`/`VPC_LINK` integration;
      JWT authorizer needs backend JWKS (HS256→RS256 move — real backend change; use a Lambda
      authorizer or throttling-only in the meantime); custom domain `api.${DomainName}`.
- [ ] **5.2** Cost note: VPC Link (~$7.30/mo) + internal ALB (~$16/mo) is the most expensive item
      in the whole plan. Consider build-screenshot-teardown if nothing consumes it long-term.

### Phase 6 — Hardening and second environment (~3 days infra)

- [ ] **6.1** VPC endpoints (G9) — `templates/vpc-endpoints.yaml`: free S3 gateway endpoint (ECR
      layers — biggest NAT saving); interface endpoints for `ecr.api`, `ecr.dkr`, `secretsmanager`,
      `logs`, `sqs`, `sns`, `ssmmessages` (pick by value, ~$7.30/mo each); shared SG allowing 443
      from VPC CIDR; `PrivateDnsEnabled: true`.
- [ ] **6.2** RDS hardening (G16) — `DeletionProtection`, `BackupRetentionPeriod: 7` +
      backup/maintenance windows, Performance Insights (7-day free tier), postgresql log exports +
      `DatabaseConnections` alarm, `AutoMinorVersionUpgrade`. Secret rotation via AWS single-user
      Postgres Lambda (needs Lambda in-VPC — fiddliest item, optional for dev/required for prod).
      Longer term: drop master-credential usage from the app in favor of a scoped `app_user`.
- [ ] **6.3** Multi-environment (G15) — Makefile `ENV ?= dev` / `include config/$(ENV).env`;
      `config/qa.env` with non-overlapping VPC CIDR (`10.1.0.0/16`); no template changes needed.
      Matrix or `workflow_dispatch`-gate `deploy-infra.yml` for `qa`.
- [ ] **6.4** Deploy by immutable tag — app deploy workflows run
      `make deploy-service-clients-<x> CLIENTS_X_IMAGE_TAG=<sha>` instead of `:latest` +
      force-new-deployment, so rollback = redeploy a known tag. Caveat: reopens the
      service-stack-ownership race; resolve by making the app repo sole owner of that deploy path.
- [ ] **6.5** Infra CI quality gates (G18) — `cfn-lint` + Checkov in `deploy-infra.yml` before
      `deploy-platform`; `make preview` target (`--no-execute-changeset` + `describe-change-set`)
      run on PRs.
- [ ] **6.6** ECR hardening (G19) — `ScanOnPush: true`; `ImageTagMutability: IMMUTABLE` (pairs
      with 6.4's tag-based deploys); lifecycle rule keeping last 20 tagged images (currently only
      untagged images expire); repository policy if a second account ever pulls.
- [ ] **6.7** Cost guardrail — `AWS::Budgets::Budget` at a monthly threshold, SNS action on the
      existing alerts topic.

---

## Cost delta summary (dev, monthly, rough)

| Item | Δ |
|---|---|
| Route 53 hosted zone | +$0.50 |
| Domain registration | +$1.25 (amortised) |
| ACM certificates | $0 |
| CloudFront | ~$0 (free tier) |
| SNS + SQS | ~$0 (free tier) |
| `clients-worker` Fargate task (256/512, 1 task) | +$9 |
| Container Insights | +$1–3 |
| ADOT sidecars ×3 + X-Ray traces | +$2–5 |
| VPC interface endpoints ×3 | +$22 (offset by lower NAT data charges) |
| API Gateway + internal ALB (Phase 5) | +$25 |
| **Phases 0–4 + 6 without VPC endpoints/API GW** | **≈ +$15/mo** |
| **Everything** | **≈ +$60/mo** |

Existing baseline ≈ $92/mo (NAT $35 + ALB $18 + 2 Fargate tasks $18 + RDS t3.micro $15 + WAF $6).
If cost matters more than completeness, NAT Gateway is the biggest single line item — check whether
private-subnet resources actually need general internet egress before assuming VPC endpoints alone
can replace it.

## Suggested order of work

1. **Phase 0** — this week, all five items, one PR.
2. **Phase 1** — domain purchase is the long pole; start it first.
3. **Phase 2** (backend/frontend only, no infra work) runs in parallel with Phase 1.
4. **Phase 3** — most interesting to build and talk about.
5. **Phase 4** — right after Phase 3, while the async flow is fresh.
6. **Phase 6.1/6.2/6.5/6.6** — steady background hardening.
7. **Phase 5** and **Phase 6.3** — only if the portfolio story needs them.
