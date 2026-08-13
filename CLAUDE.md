# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

AWS CloudFormation infrastructure for **clients-service** (Spring Boot backend) and **clients-front** (Next.js frontend). Application source code lives in separate repositories — this repo only provisions the AWS resources they run on. There is no application code, tests, or linter here; "development" in this repo means editing CloudFormation YAML and deploying stacks via the Makefile.

## Commands

```
make validate                       # aws cloudformation validate-template on every template — run before any deploy
make deploy-network                 # VPC, subnets, NAT — everything else depends on this
make deploy-ecr                     # ECR repos — push images here before deploying services
make deploy-ecs-cluster
make deploy-alb
make deploy-rds
make deploy-service-clients-service
make deploy-service-clients-front
make deploy-platform                # network, ecr, ecs-cluster, alb, rds — what CI runs
make deploy-all-services            # both service-clients-* stacks
make deploy-all                     # deploy-platform + deploy-all-services
```

Deploy order matters on first deploy (dependency chain via `Fn::ImportValue`); after that, any single stack can be redeployed independently.

`.github/workflows/deploy-infra.yml` only ever runs `make deploy-platform`, and only triggers on
pushes touching the platform templates, `config/**`, or `Makefile` — never on
`templates/service-clients-*.yaml`. That's deliberate: the ECS Service + TaskDefinition those
templates own is also driven directly by `clients-service`'s and `clients-front`'s own
`deploy.yml` (`aws ecs update-service --force-new-deployment`), so auto-deploying the service
stacks here on every infra push would race those app-repo deploys of the same ECS service.
Deploy service-stack changes with `make deploy-service-clients-service` /
`deploy-service-clients-front` by hand instead, once no app deploy is in flight.

To deploy a single stack manually with different parameters, copy the relevant `$(DEPLOY) ...` block from the `Makefile` rather than editing the target itself.

Pushing images (after `make deploy-ecr`, get repo URIs from stack outputs):
```
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-west-1.amazonaws.com
docker tag clients-service:latest <clients-service-repo-uri>:latest
docker push <clients-service-repo-uri>:latest
```
The ECS services need at least one image pushed to start successfully.

## Architecture

- Region `eu-west-1`, compute is ECS Fargate, data is RDS Postgres (clients-service only), images in ECR, `dev` environment only for now.
- `clients-front` (Next.js) is a server-side BFF — it holds the session (JWT cookie signed with `SESSION_SECRET`) and calls `clients-service` (Spring Boot) server-side, never from the browser. Only `clients-front` sits behind the public ALB.
- `clients-service` is internal-only, reached via a private Cloud Map DNS namespace (`clients-service.<Environment>.internal`, e.g. `clients-service.dev.internal:8080`) created in `ecs-cluster.yaml`.
- `clients-front`'s task gets `BACKEND_API_URL` pointing at that Cloud Map DNS name, and `SESSION_SECRET` from Secrets Manager.
- Stacks are independent, linked only via `Fn::ImportValue` on exports named `${Environment}-<resource>` (e.g. `dev-VpcId`) — never hardcode cross-stack resource IDs, always `!ImportValue` the export.
- `config/dev.env` holds all per-environment parameter values; the Makefile `include`s it and exports every variable so template parameters stay out of the Makefile itself. Templates themselves take an `Environment` parameter and are otherwise environment-agnostic.

### Adding another environment

Copy `config/dev.env` to e.g. `config/qa.env`, adjust values, and either parameterize the Makefile with an `ENV_FILE` variable or duplicate the targets. Templates need no changes since everything is parameterized by `Environment`.

## Known placeholders / unfinished state

- ALB is plain HTTP (no domain/ACM cert yet).
- Container ports: clients-service `8080`, clients-front `3000` — confirmed against the app repos.
- clients-front health check path `/` (marketing landing page) is a reasonable default. clients-service has no code yet, so its actual health endpoint (e.g. Spring Boot Actuator `/actuator/health`) is unconfirmed — it currently has no ALB health check at all since it isn't behind the ALB.
- Neither app repo has a Dockerfile yet — needed before `make deploy-service-*` can succeed.
- Single NAT Gateway and single-AZ RDS are deliberate dev cost tradeoffs; revisit for `qa`/`prod` (NAT per AZ, Multi-AZ RDS, larger instance sizing, autoscaling).
