# Implementation plan — `clients-infra`

The AWS/CloudFormation workstream for the improvements in
[`ARCHITECTURE_IMPROVEMENTS.md`](./ARCHITECTURE_IMPROVEMENTS.md). Gap IDs (`G1`…`G21`) and phase
numbers refer to that document. Sibling plans:

- `clients-service/docs/IMPLEMENTATION_PLAN.md`
- `clients-front/docs/IMPLEMENTATION_PLAN.md`

Conventions this repo already enforces and that every task below inherits: one template per stack,
cross-stack wiring only through `Fn::ImportValue` on `${Environment}-*` exports, all parameter
values in `config/<env>.env`, tags applied once via the Makefile's `TAGS`, `make validate` before
any deploy, and service stacks deployed by hand (never by `deploy-infra.yml`) so they don't race the
app repos' `force-new-deployment`.

---

## Phase 0 — Correctness fixes (~1 day)

Do these first; each is small and each closes a real defect in the running `dev` environment.

### 0.1 Inject `SECURITY_JWT_SECRET` into `clients-service` (G1) — **critical**

The deployed backend is signing tokens with the labelled dev-only default from
`application.properties`, because the task definition injects only `DB_*`.

In `templates/service-clients-service.yaml`:

- Add a `JwtSecret` `AWS::SecretsManager::Secret` mirroring how `service-clients-front.yaml`
  generates `SessionSecret` (`GenerateSecretString`, `PasswordLength: 64`,
  `ExcludeCharacters: '"@/\'`), named `camedina-${Environment}-clients-service-jwt`.
- Add it to `TaskExecutionRole`'s `ReadDbSecret` policy (rename to `ReadSecrets`) as a second
  `Resource`.
- Add to the container's `Secrets`: `- Name: SECURITY_JWT_SECRET / ValueFrom: !Ref JwtSecret`.
- Add `- Name: SPRING_PROFILES_ACTIVE / Value: !Ref Environment` to `Environment` while in here, so
  `application-dev.properties` becomes usable.

Deploy with `make deploy-service-clients-service`. **Note:** rotating this secret invalidates every
issued token — all users are logged out once. Do it before the system has users who'd notice.

### 0.2 ECS container health checks + readiness probes (G5)

Fargate ignores the Dockerfile `HEALTHCHECK`; ECS only honours `ContainerDefinition.HealthCheck`.

`service-clients-service.yaml`, container `clients-service`:

```yaml
HealthCheck:
  Command: ["CMD-SHELL", "wget -q --spider http://localhost:8080/actuator/health/readiness || exit 1"]
  Interval: 30
  Timeout: 5
  Retries: 3
  StartPeriod: 60
```

`service-clients-front.yaml`, container `clients-front`: same shape against
`http://localhost:3000/api/health` (a new route — see the frontend plan).

This depends on the backend enabling Spring Boot's liveness/readiness probe groups and the frontend
adding a health route; sequence it with those, or point at `/actuator/health` and `/` in the interim.

### 0.3 Deployment circuit breaker with rollback (G8)

Both `AWS::ECS::Service` resources:

```yaml
DeploymentConfiguration:
  MaximumPercent: 200
  MinimumHealthyPercent: 100
  DeploymentCircuitBreaker:
    Enable: true
    Rollback: true
```

Highest value-per-line change in the repo: a task that fails its health check now rolls back to the
previous task definition instead of flapping forever.

### 0.4 Enable ECS Exec (G21)

Add `EnableExecuteCommand: true` to both services and grant the `TaskRole`:

```yaml
Policies:
  - PolicyName: EcsExec
    PolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Action:
            - ssmmessages:CreateControlChannel
            - ssmmessages:CreateDataChannel
            - ssmmessages:OpenControlChannel
            - ssmmessages:OpenDataChannel
          Resource: '*'
```

Then `aws ecs execute-command --cluster camedina-dev-cluster --task <id> --interactive --command /bin/sh`
replaces "redeploy with a debug log line" as the debugging loop.

### 0.5 Enable Container Insights (G11)

`ecs-cluster.yaml`: `ClusterSettings` → `containerInsights: enhanced` (or `enabled` for the cheaper
classic version). Adds per-task CPU/memory/network metrics that the Phase 4 dashboard needs. Small
ongoing cost — check it against expectations after a week.

**Phase 0 exit criteria:** backend token signed with a real secret; a deliberately broken image
rolls back automatically; `aws ecs execute-command` opens a shell in a running task.

---

## Phase 1 — Edge: TLS, custom domain, CloudFront (~2 days)

Implements ADR-001. Closes G2, G3, and part of G14.

### 1.1 Prerequisite: a domain

Register or transfer a domain into Route 53 (a `.dev`/`.io` runs ~$12–15/yr; this is the only
unavoidable cost in the whole plan). Everything below assumes a hosted zone exists.

New `config/dev.env` values:

```
DOMAIN_NAME=camedina.dev
HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ
APP_SUBDOMAIN=app
```

### 1.2 New stack: `templates/dns-certificate.yaml`

- `AWS::CertificateManager::Certificate` for `${AppSubdomain}.${DomainName}` — **must be created in
  `us-east-1`** to be usable by CloudFront. Options: a second small stack deployed with
  `--region us-east-1` (add `make deploy-certificate-edge`), or a `AWS::CloudFormation::StackSet`.
  The simpler path is a separate `make` target with an explicit `--region`; document the exception
  loudly since every other stack in this repo is regional.
- A second, `eu-west-1` certificate for the ALB's HTTPS listener if the origin is to be TLS-
  terminated too (recommended: yes, CloudFront → ALB over HTTPS).
- Exports: `${Environment}-edge-certificate-arn`, `${Environment}-regional-certificate-arn`,
  `${Environment}-hosted-zone-id`.

Both certificates use `ValidationMethod: DNS` with `DomainValidationOptions.HostedZoneId`, so
validation records are created automatically and the stack doesn't hang on manual DNS.

### 1.3 `templates/alb.yaml` — HTTPS listener + origin lock

- Add an `AWS::ElasticLoadBalancingV2::Listener` on port 443, `Protocol: HTTPS`, `Certificates:
  [!ImportValue ${Environment}-regional-certificate-arn]`, `SslPolicy:
  ELBSecurityPolicy-TLS13-1-2-2021-06`, default action `fixed-response 404` (matching the current
  :80 listener's shape). Export its ARN as `${Environment}-alb-https-listener-arn`.
- Change the :80 listener's default action to a `redirect` to HTTPS (`StatusCode: HTTP_301`).
- **Origin lock**: add an `OriginVerifySecret` (`AWS::SecretsManager::Secret`, generated) and, on
  the HTTPS listener, a low-priority rule that returns `403` unless
  `http-header X-Origin-Verify == <secret>`. CloudFront injects that header via
  `OriginCustomHeaders`. This is the pragmatic alternative to CloudFront VPC origins, which require
  the ALB to be `Scheme: internal` — a replacement-triggering change on an existing ALB.
- Narrow `AlbSecurityGroup` ingress from `0.0.0.0/0` to the `com.amazonaws.global.cloudfront.origin-facing`
  managed prefix list (`SourcePrefixListId`), so only CloudFront IPs can even reach the ALB.

Between the prefix list and the header check, the frontend is no longer directly reachable — which
is the actual goal behind "an API gateway so the front isn't exposed".

### 1.4 New stack: `templates/cdn.yaml`

`AWS::CloudFront::Distribution` with:

- **Origin**: the ALB DNS name (`!ImportValue ${Environment}-alb-dns-name`),
  `CustomOriginConfig.OriginProtocolPolicy: https-only`, `OriginCustomHeaders` carrying
  `X-Origin-Verify`.
- **Default cache behaviour**: `CachePolicyId` = managed `CachingDisabled`,
  `OriginRequestPolicyId` = managed `AllViewer`, `ViewerProtocolPolicy: redirect-to-https`,
  all methods allowed. SSR pages and API calls must not be cached, and cookies/headers must reach
  the origin intact — this is the behaviour that keeps the BFF working.
- **Cache behaviour for `/_next/static/*`** (and `/favicon.ico`, `/public/*`): managed
  `CachingOptimized`, `OriginRequestPolicy` = `CORS-S3Origin`-style minimal forwarding, methods
  `GET, HEAD`. Next.js content-hashes these filenames, so they're safely immutable.
- `Aliases: [!Sub '${AppSubdomain}.${DomainName}']`, `ViewerCertificate` from the us-east-1 ACM ARN,
  `MinimumProtocolVersion: TLSv1.2_2021`.
- A **response headers policy** adding HSTS, `X-Content-Type-Options`, `Referrer-Policy` and a
  starter CSP.
- `AWS::Route53::RecordSet` (A + AAAA alias) pointing the subdomain at the distribution.
- Export `${Environment}-cdn-domain-name`, `${Environment}-cdn-distribution-id`.

CloudFront distributions take 5–15 minutes to deploy; budget for slow iterations.

### 1.5 `templates/waf.yaml` — rate limiting (G14)

Add a rate-based rule ahead of the managed groups:

```yaml
- Name: RateLimitPerIp
  Priority: 2
  Action:
    Block: {}
  Statement:
    RateBasedStatement:
      Limit: 2000
      AggregateKeyType: IP
  VisibilityConfig: { ... }
```

Plus a tighter scoped-down rule (`Limit: 100`) that only counts requests where the URI path starts
with `/login` or `/signup`, so credential stuffing is throttled well below the general limit.

The WebACL stays **regional on the ALB**. A second `Scope: CLOUDFRONT` WebACL (which must be created
in us-east-1) is optional; blocking at the ALB is sufficient and avoids a second us-east-1 exception.

### 1.6 Makefile

```make
deploy-certificate-edge:    # NOTE: us-east-1, CloudFront requirement
deploy-dns-certificate:
deploy-cdn:
```

Add `dns-certificate` and `cdn` to `deploy-platform` and to `deploy-infra.yml`'s trigger paths.
Order: `dns-certificate` → `alb` → `waf` → `cdn`.

**Phase 1 exit criteria:** `https://app.<domain>` serves the app; `http://` redirects; the ALB DNS
name returns 403 when hit directly; `Secure` cookies survive a login round-trip; `/_next/static/*`
returns `x-cache: Hit from cloudfront` on a second request.

---

## Phase 3 — Event backbone (~2 days infra, ~3 days app)

Implements ADR-002 and ADR-003. Infra side only here; producer/consumer code is in the backend plan.

### 3.1 New stack: `templates/messaging.yaml`

- `DomainEventsTopic` — `AWS::SNS::Topic`, `camedina-${Environment}-domain-events`. Distinct from
  the existing `alerts` topic, which is for CloudWatch alarms and must not be mixed with domain
  events.
- Per consumer, a triple:
  - `<Name>Queue` — `AWS::SQS::Queue`, `VisibilityTimeout: 60` (must exceed the worker's longest
    handler runtime), `MessageRetentionPeriod: 1209600` (14 d),
    `RedrivePolicy: { deadLetterTargetArn: <dlq>, maxReceiveCount: 5 }`.
  - `<Name>Dlq` — `AWS::SQS::Queue`, 14-day retention.
  - `<Name>Subscription` — `AWS::SNS::Subscription`, `Protocol: sqs`, `RawMessageDelivery: true`,
    `FilterPolicyScope: MessageAttributes`, `FilterPolicy: { eventType: [ ... ] }`.
  - `<Name>QueuePolicy` — `AWS::SQS::QueuePolicy` allowing `sns.amazonaws.com` to `sqs:SendMessage`
    with a `aws:SourceArn` condition on the topic. Easy to forget; without it the subscription
    silently delivers nothing.

Start with two consumers: `notifications` (filter: `ProjectStatusChanged`, `UserRegistered`) and
`jobs` (filter: `BulkImportRequested`, `ReportRequested`).

- Alarms per queue, publishing to `${Environment}-alerts-topic-arn`:
  - DLQ `ApproximateNumberOfMessagesVisible > 0` for 1 period → something is failing permanently.
  - Main queue `ApproximateAgeOfOldestMessage > 300` → the worker is down or too slow.
- Exports: `${Environment}-domain-events-topic-arn`, `${Environment}-<name>-queue-url`,
  `${Environment}-<name>-queue-arn`, `${Environment}-<name>-dlq-arn`.

### 3.2 `templates/service-clients-service.yaml` — producer permissions (G13)

Add to `TaskRole`:

```yaml
- PolicyName: PublishDomainEvents
  PolicyDocument:
    Version: '2012-10-17'
    Statement:
      - Effect: Allow
        Action: sns:Publish
        Resource: !ImportValue
          Fn::Sub: ${Environment}-domain-events-topic-arn
```

Add `DOMAIN_EVENTS_TOPIC_ARN` to the container `Environment`.

### 3.3 New stack: `templates/service-clients-worker.yaml`

Modelled on `service-clients-service.yaml`, minus the ALB/Cloud Map bits:

- Same ECR image (`${Environment}-clients-service-repo-uri`) — one image, two roles.
- `Environment`: `SPRING_PROFILES_ACTIVE=worker`, `DB_*`, queue URLs; `Secrets`: DB creds + JWT
  secret (needed if the worker validates or issues anything; drop it if not).
- `TaskRole` policy: `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`,
  `sqs:ChangeMessageVisibility` on the two queue ARNs, plus `ses:SendEmail` once notifications are
  real.
- **No** `ServiceRegistries`, **no** `LoadBalancers` — nothing calls it, it only pulls.
- A `SecurityGroupIngress` on the RDS security group scoped to the worker's own task SG (same
  pattern `service-clients-service.yaml` already uses to avoid the circular dependency).
- **Queue-depth autoscaling**, deliberately different from the CPU/memory policies on the other two
  services:

```yaml
BacklogScalingPolicy:
  Type: AWS::ApplicationAutoScaling::ScalingPolicy
  Properties:
    PolicyType: TargetTrackingScaling
    TargetTrackingScalingPolicyConfiguration:
      CustomizedMetricSpecification:
        Metrics:
          - Id: backlogPerTask
            Expression: visible / IF(tasks < 1, 1, tasks)
            ReturnData: true
          - Id: visible
            MetricStat: { Metric: { Namespace: AWS/SQS, MetricName: ApproximateNumberOfMessagesVisible, ... }, Stat: Average }
            ReturnData: false
          - Id: tasks
            MetricStat: { Metric: { Namespace: ECS/ContainerInsights, MetricName: RunningTaskCount, ... }, Stat: Average }
            ReturnData: false
      TargetValue: 20
```

`MinCapacity: 0` is tempting for cost but means a cold start on the first message; `1` is the
sensible dev default. Note the metric-math target-tracking policy requires Container Insights from
step 0.5.

### 3.4 Makefile + config

New `config/dev.env` block:

```
# service-clients-worker.yaml
CLIENTS_WORKER_CPU=256
CLIENTS_WORKER_MEMORY=512
CLIENTS_WORKER_DESIRED_COUNT=1
CLIENTS_WORKER_MIN_CAPACITY=1
CLIENTS_WORKER_MAX_CAPACITY=5
CLIENTS_WORKER_IMAGE_TAG=latest
```

Targets: `deploy-messaging` (goes into `deploy-platform`, since no app repo drives it) and
`deploy-service-clients-worker` (goes into `deploy-all-services`, deployed by hand — same race
reasoning as the other two service stacks).

**Phase 3 exit criteria:** publishing a test message to the SNS topic lands in both queues; killing
the worker makes `ApproximateAgeOfOldestMessage` alarm; a handler that always throws sends the
message to the DLQ after 5 attempts and fires the DLQ alarm.

---

## Phase 4 — Observability (~2 days infra)

### 4.1 X-Ray / ADOT sidecar

Add a second container to each of the three task definitions:

```yaml
- Name: aws-otel-collector
  Image: public.ecr.aws/aws-observability/aws-otel-collector:latest
  Command: ["--config=/etc/ecs/ecs-default-config.yaml"]
  LogConfiguration: { ... }
```

Grant each `TaskRole` the `AWSXRayDaemonWriteAccess` managed policy. App-side instrumentation is in
the per-repo plans. Bump task `Memory` to 1024 — the sidecar plus a JVM in 512 MB is tight.

### 4.2 New stack: `templates/dashboard.yaml`

One `AWS::CloudWatch::Dashboard` per environment, four rows:

1. **Edge** — CloudFront requests, 4xx/5xx rate, cache hit rate; ALB `RequestCount`,
   `TargetResponseTime` p50/p95/p99, `HTTPCode_ELB_5XX_Count`.
2. **Compute** — per service: CPU, memory, `RunningTaskCount`, plus the deployment state.
3. **Data** — RDS `CPUUtilization`, `DatabaseConnections`, `FreeStorageSpace`, `ReadLatency`/
   `WriteLatency`.
4. **Async** — per queue: messages visible, age of oldest, messages sent/received/deleted; DLQ
   depth.

Keep the JSON in the template rather than clicking it in the console — a dashboard built by hand
disappears with the account and proves nothing.

### 4.3 Log retention and metric filters

Both existing log groups are 14 days, which is fine. Add `AWS::Logs::MetricFilter` on the backend
log group for `level=ERROR` → a custom metric → an alarm on the alerts topic, so application errors
reach the same email path as infrastructure alarms.

---

## Phase 5 — Public API via API Gateway (~2 days)

The version of "put an API gateway in front" that holds up architecturally: it fronts the **API**,
not the SSR app. See ADR-001.

### 5.1 New stack: `templates/api-gateway.yaml`

- An **internal** `AWS::ElasticLoadBalancingV2::LoadBalancer` (`Scheme: internal`, private subnets)
  with a listener + target group pointing at `clients-service`. VPC Links require an ALB/NLB target;
  they cannot integrate with Cloud Map directly. The BFF keeps using Cloud Map DNS — this ALB exists
  purely for the public API path.
- `AWS::ApiGatewayV2::VpcLink` in the private subnets, with its own security group allowed into the
  backend task SG on 8080.
- `AWS::ApiGatewayV2::Api` (`ProtocolType: HTTP`), a `$default` stage with
  `DefaultRouteSettings.ThrottlingRateLimit`/`ThrottlingBurstLimit` set, and access logging to a
  CloudWatch log group.
- `AWS::ApiGatewayV2::Integration` (`HTTP_PROXY`, `ConnectionType: VPC_LINK`) + routes.
- `AWS::ApiGatewayV2::Authorizer` of type `JWT`, `IdentitySource: $request.header.Authorization`,
  pointed at the backend's issuer — which requires the backend to expose a JWKS endpoint, i.e. a
  move from HS256 to RS256. That's a real backend change (see the backend plan); until then, use a
  `Lambda` authorizer or leave the backend's own filter as the only check and use API Gateway purely
  for throttling.
- A custom domain (`api.${DomainName}`) + `AWS::ApiGatewayV2::ApiMapping` + Route 53 record.

### 5.2 Cost note

VPC Link (~$0.01/hr ≈ $7.30/mo) plus the internal ALB (~$16/mo) is the most expensive item in this
entire plan and buys a capability nothing currently consumes. Build it when there is a reason to
demonstrate it — or build it, screenshot it, document it, and tear it down. Say so in the README
either way; "I built it and removed it because nothing used it" is a better answer than an idle
$25/mo line item.

---

## Phase 6 — Hardening and second environment (~3 days infra)

### 6.1 VPC endpoints (G9) — `templates/vpc-endpoints.yaml`

- **Gateway endpoints (free)**: S3 (ECR layer storage lives in S3 — this is the single biggest NAT
  data-transfer saving), DynamoDB if ever needed.
- **Interface endpoints (~$7.30/mo each + data)**: `ecr.api`, `ecr.dkr`, `secretsmanager`, `logs`,
  `sqs`, `sns`, `ssmmessages` (for ECS Exec). Pick by value: `ecr.dkr` + `ecr.api` + the free S3
  gateway covers most of it; add `logs` and `sqs` if the NAT bill justifies it.
- A shared endpoint security group allowing 443 from the VPC CIDR.
- Set `PrivateDnsEnabled: true` so no application config changes.

### 6.2 RDS hardening (G16) — `templates/rds.yaml`

- `DeletionProtection: true` (parameterised, `false` in dev if teardown matters).
- `BackupRetentionPeriod: 7`, `PreferredBackupWindow`, `PreferredMaintenanceWindow`.
- `EnablePerformanceInsights: true`, `PerformanceInsightsRetentionPeriod: 7` (free tier).
- `EnableCloudwatchLogsExports: [postgresql]` + a `DatabaseConnections` alarm.
- `AutoMinorVersionUpgrade: true`.
- Add `AWS::SecretsManager::RotationSchedule` on the DB secret using the AWS-provided single-user
  Postgres rotation Lambda. **This needs the Lambda in the VPC with access to RDS** — it's the
  fiddliest item in Phase 6; consider it optional for `dev` and required for any `prod`.
- Longer term: stop using the master credential from the app. Create an `app_user` with only DML
  grants in a Flyway migration and give the task a separate secret.

### 6.3 Multi-environment (G15) — Makefile

Replace the hardcoded `include config/dev.env` with:

```make
ENV ?= dev
include config/$(ENV).env
```

so `make deploy-all ENV=qa` works. Then add `config/qa.env` with a non-overlapping VPC CIDR
(`10.1.0.0/16`) and smaller/identical sizing. Templates need no changes — everything is already
parameterised by `Environment`, which is the payoff for that discipline.

Update `deploy-infra.yml` to matrix over environments, or gate `qa` behind `workflow_dispatch`.

### 6.4 Deploy by immutable tag

Both app repos push `:latest` and `:<sha>`, then `force-new-deployment`. That means a rollback
requires retagging in ECR. Change the app deploy workflows to instead run
`make deploy-service-clients-<x> CLIENTS_X_IMAGE_TAG=<sha>`, or `aws ecs update-service` against a
task definition revision registered with the SHA. Rollback then becomes redeploying a known tag.

Caveat: this reopens the race the current split deliberately avoids. Resolve it by making the app
repo the sole owner of the service stack deploy (and dropping the manual `make deploy-service-*`
path), rather than by having both drive it.

### 6.5 Infra CI quality gates (G18)

In `deploy-infra.yml`, before `make deploy-platform`:

```yaml
- run: pip install cfn-lint
- run: cfn-lint templates/*.yaml
- uses: bridgecrewio/checkov-action@master
  with: { directory: templates/, framework: cloudformation }
```

Add a `make preview` target using `aws cloudformation deploy --no-execute-changeset` plus
`describe-change-set`, and run it on pull requests so a PR shows what it would change.

### 6.6 ECR hardening (G19) — `templates/ecr.yaml`

- `ImageScanningConfiguration: { ScanOnPush: true }`.
- `ImageTagMutability: IMMUTABLE` — requires dropping the `:latest` retag, so it pairs with 6.4.
- Add a second lifecycle rule keeping the last 20 tagged images (currently only untagged images
  expire, so tagged images accumulate forever).
- An `AWS::ECR::RepositoryPolicy` if a second account ever pulls.

### 6.7 Cost guardrail

An `AWS::Budgets::Budget` at a monthly threshold with an SNS action on the existing alerts topic.
Cheap insurance, and the sort of thing that reads as operational maturity.

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

Existing baseline is roughly NAT ($35) + ALB ($18) + 2 Fargate tasks ($18) + RDS t3.micro ($15) +
WAF ($6) ≈ $92/mo, so Phases 0–4 are a ~15% increase. If cost matters more than completeness, the
NAT Gateway is the biggest single line item — replacing it with VPC endpoints only (no NAT) is
possible if nothing in a private subnet needs general internet egress, which is worth checking.

---

## Suggested order of work

1. **Phase 0** — this week, all five items, one PR.
2. **Phase 1** — the domain purchase is the long pole; start it first.
3. **Phase 2** (backend/frontend only, no infra work) runs in parallel with Phase 1.
4. **Phase 3** — the most interesting one to build and to talk about.
5. **Phase 4** — do it right after Phase 3, while the async flow is fresh and worth a service-map
   screenshot.
6. **Phase 6.1/6.2/6.5/6.6** — steady background hardening.
7. **Phase 5** and **Phase 6.3** — only if the portfolio story needs them.

## How to update this doc

Same convention as `docs/PLAN.md` in the app repos: strike finished items, move the detail into
`README.md`/`CLAUDE.md` when it becomes how the repo actually works, and keep the gap IDs so this
file and `ARCHITECTURE_IMPROVEMENTS.md` stay in sync.
