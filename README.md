# camedina-infra

AWS CloudFormation infrastructure for **clients-service** (backend) and **clients-front** (frontend). Application source code lives in separate repositories; this repo only provisions the AWS resources they run on.

## Stack

- Region: `eu-west-1`
- Compute: ECS Fargate
- Data: RDS Postgres (clients-service only)
- Images: ECR (repos created here)
- Environment: `dev` only for now

## Architecture

`clients-front` (Next.js) is a server-side BFF — it holds the session (JWT cookie signed with `SESSION_SECRET`) and calls `clients-service` (Spring Boot) server-side, never from the browser. So only `clients-front` sits behind the public ALB; `clients-service` is internal-only, reached via a private Cloud Map DNS namespace (`clients-service.<Environment>.internal`, e.g. `clients-service.dev.internal:8080`) created in `ecs-cluster.yaml`. `clients-front`'s task gets `BACKEND_API_URL` pointing at that DNS name and `SESSION_SECRET` from Secrets Manager.

## Prerequisites

- AWS CLI v2 installed and configured (`aws configure`), with a region of `eu-west-1`
- Credentials with permission to create VPC/ECS/RDS/IAM/ECR/ALB resources
- `make`

## Layout

```
templates/   CloudFormation templates, one per stack
config/      per-environment parameter values (dev.env)
Makefile     wraps `aws cloudformation deploy` per stack
```

Stacks are independent (linked via `Fn::ImportValue` exports named `${Environment}-<resource>`), so any single stack can be redeployed without touching the others — as long as dependency order below is respected on first deploy.

## Current deployment status (dev, as of 2026-08-13)

- `camedina-dev-network`, `camedina-dev-ecr`, `camedina-dev-ecs-cluster`, `camedina-dev-alb`,
  `camedina-dev-rds` — deployed
- `camedina-dev-github-oidc` — deployed (bootstrap stack, applied by hand per its own header
  comment — not part of `deploy-all`/`deploy-platform`). Its trust policy lists both the
  plain-name and `@<immutable-id>`-qualified `sub` forms for the `Alpoh` org and its repos,
  since GitHub was still emitting the id-qualified form post-rename as of this date.
- `camedina-dev-service-clients-service`, `camedina-dev-service-clients-front` — deployed, both
  ECS services `ACTIVE` with 1/1 tasks running
- `clients-front`'s own `ci-cd.yml` verified working end-to-end (build, ECR push, ECS
  force-redeploy) via a live GitHub Actions run on 2026-08-13

## Deploy order (dev)

```
make validate                       # lint all templates first
make deploy-network                 # VPC, subnets, NAT - everything else depends on this
make deploy-ecr                     # ECR repos - push images here before deploying services
make deploy-ecs-cluster
make deploy-alb
make deploy-rds
make deploy-service-clients-service
make deploy-service-clients-front
```

Or `make deploy-all` to run all of the above in order.

## CI/CD ownership split

`.github/workflows/deploy-infra.yml` only runs `make deploy-platform` (network, ecr,
ecs-cluster, alb, rds), triggered on push to templates for those stacks, `config/**`, or
`Makefile`. It deliberately excludes `templates/service-clients-*.yaml` and the
`deploy-service-*`/`deploy-all-services` targets: those own the ECS Service + TaskDefinition
that `clients-service`'s and `clients-front`'s own `deploy.yml` workflows also drive directly
via `aws ecs update-service --force-new-deployment`. Auto-deploying the service stacks here too
would let an infra-only push race an app's own deploy of the same ECS service. Run
`make deploy-all-services` (or a single `make deploy-service-*`) by hand for first bootstrap or
a deliberate task-level change (Cpu/Memory/DesiredCount), after checking no app deploy is in
flight.

## Pushing images

After `make deploy-ecr`, get the repo URIs from the stack outputs and push:

```
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-west-1.amazonaws.com
docker tag clients-service:latest <clients-service-repo-uri>:latest
docker push <clients-service-repo-uri>:latest
```

The ECS services (`deploy-service-clients-service` / `deploy-service-clients-front`) need at least one image pushed to start successfully.

## Known placeholders to revisit

- ALB is plain HTTP (no domain/ACM cert yet)
- Container ports confirmed against the app repos: clients-service `8080` (Spring Boot default, per `clients-front`'s `.env.local.example`), clients-front `3000` (Next.js `next start` default)
- clients-front health check path `/` is a reasonable default (marketing landing page). clients-service has no code yet (empty repo as of 2026-08-07) so its actual health endpoint (e.g. Spring Boot Actuator `/actuator/health`) is unconfirmed — it currently has no ALB health check at all since it's not behind the ALB; add one via the Cloud Map `HealthCheckCustomConfig` or ECS container health check once the app exists
- Single NAT Gateway and single-AZ RDS are dev cost tradeoffs; revisit for a `qa`/`prod` environment (NAT per AZ, Multi-AZ RDS, larger instance sizing, autoscaling)

## Adding another environment

Copy `config/dev.env` to e.g. `config/qa.env`, adjust values, and either parameterize the Makefile with an `ENV_FILE` variable or duplicate the targets — templates themselves need no changes since everything is parameterized by `Environment`.
