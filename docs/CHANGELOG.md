# Changelog

All notable changes to this infrastructure repository are documented in this file.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This repo has
no version tags — entries are grouped by change instead of release number, newest first.

## Unreleased

- Added `docs/ARCHITECTURE_IMPROVEMENTS.md` and `docs/IMPLEMENTATION_PLAN.md` documenting known
  architecture gaps and a plan for addressing them.

## 2026-08-14 — Tagging, alerting, autoscaling, and WAF

Closed several known gaps in the platform stacks:

- Added `templates/alerting.yaml`: SNS alerts topic with an email subscription
  (`ALERT_EMAIL` in `config/dev.env`), exported as `${Environment}-alerts-topic-arn`.
- Added `templates/waf.yaml`: regional WAFv2 WebACL (AWS managed Common + KnownBadInputs rule
  groups) attached to the ALB.
- Added Application Auto Scaling (CPU/memory target-tracking policies, `MinCapacity`/
  `MaxCapacity`) to both `service-clients-front.yaml` and `service-clients-service.yaml`.
- Added CloudWatch alarms (CPU/memory/storage/unhealthy-host) on `rds.yaml` and both service
  stacks, publishing to the new alerting SNS topic.
- Added `Owner` to the shared `TAGS` Makefile variable applied to every stack deploy.
- Added `make deploy-alerting` and `make deploy-waf` Makefile targets; `deploy-platform` now
  includes alerting and waf in its deploy order (alerting before rds/services, waf after alb).

## 2026-08-13 — GitHub OIDC and CI/CD

- Added `templates/github-oidc.yaml`: IAM OIDC provider and role so GitHub Actions can deploy
  without long-lived AWS credentials.
- Added `.github/workflows/deploy-infra.yml`: CI workflow running `make deploy-platform` on
  pushes touching platform templates, `config/**`, or the `Makefile` — deliberately excluding
  `templates/service-clients-*.yaml` to avoid racing the app repos' own ECS deploys.
- Documented the CI trigger scope and the reasoning behind excluding the service stacks in
  `CLAUDE.md` and `README.md`.

## 2026-08-09 — Initial documentation

- Added `CLAUDE.md` with guidance for Claude Code on repo structure, commands, and architecture.
- Expanded `.gitignore` and documented deploy steps in `README.md`.

## 2026-08-07 — Baseline infrastructure

Initial commit of the CloudFormation stacks and deploy tooling for `clients-service` and
`clients-front`:

- `templates/network.yaml` — VPC, subnets, NAT gateway.
- `templates/ecr.yaml` — ECR repositories for both services.
- `templates/ecs-cluster.yaml` — ECS Fargate cluster and Cloud Map private DNS namespace.
- `templates/alb.yaml` — public Application Load Balancer (HTTP only, no ACM cert yet).
- `templates/rds.yaml` — RDS Postgres instance for `clients-service`.
- `templates/service-clients-front.yaml` / `templates/service-clients-service.yaml` — ECS
  services and task definitions.
- `Makefile` with per-stack deploy targets and `config/dev.env` for environment parameters.
- `README.md` with initial setup and deploy instructions.
