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
- Neither app repo has a Dockerfile yet — needed before `make deploy-service-*` can succeed (ECS tasks need something to pull from ECR)
- Single NAT Gateway and single-AZ RDS are dev cost tradeoffs; revisit for a `qa`/`prod` environment (NAT per AZ, Multi-AZ RDS, larger instance sizing, autoscaling)

## Adding another environment

Copy `config/dev.env` to e.g. `config/qa.env`, adjust values, and either parameterize the Makefile with an `ENV_FILE` variable or duplicate the targets — templates themselves need no changes since everything is parameterized by `Environment`.
