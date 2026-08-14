include config/dev.env
export

STACK_NAME_PREFIX = $(STACK_PREFIX)-$(ENVIRONMENT)
# Stack-level tags propagate to every taggable resource CloudFormation creates
# in the stack, so this is the one place tagging policy lives - no per-resource
# Tags blocks needed in the templates themselves.
TAGS = --tags Project=clients Environment=$(ENVIRONMENT) ManagedBy=cloudformation Owner=$(STACK_PREFIX)
DEPLOY = aws cloudformation deploy --region $(AWS_REGION) --capabilities CAPABILITY_NAMED_IAM $(TAGS)

.PHONY: deploy-network deploy-ecr deploy-ecs-cluster deploy-alb deploy-rds \
        deploy-alerting deploy-waf \
        deploy-service-clients-service deploy-service-clients-front \
        deploy-platform deploy-all-services deploy-all \
        deploy-github-oidc validate

validate:
	for f in templates/*.yaml; do \
		echo "Validating $$f"; \
		aws cloudformation validate-template --region $(AWS_REGION) --template-body file://$$f > /dev/null; \
	done

# Bootstrap only - deploy by hand once with camilo-cli, not part of deploy-all.
# Creates the OIDC trust the GitHub Actions workflows assume, so it can't
# depend on CI already being able to authenticate. Requires deploy-ecr to
# have run first (imports the ECR repo ARNs).
deploy-github-oidc:
	$(DEPLOY) \
		--template-file templates/github-oidc.yaml \
		--stack-name $(STACK_NAME_PREFIX)-github-oidc \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			GitHubOrg=$(GITHUB_ORG) \
			InfraRepo=$(GITHUB_INFRA_REPO) \
			ServiceRepo=$(GITHUB_SERVICE_REPO) \
			FrontRepo=$(GITHUB_FRONT_REPO)

deploy-alerting:
	$(DEPLOY) \
		--template-file templates/alerting.yaml \
		--stack-name $(STACK_NAME_PREFIX)-alerting \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			AlertEmail=$(ALERT_EMAIL)

deploy-network:
	$(DEPLOY) \
		--template-file templates/network.yaml \
		--stack-name $(STACK_NAME_PREFIX)-network \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			VpcCidr=$(VPC_CIDR) \
			PublicSubnet1Cidr=$(PUBLIC_SUBNET_1_CIDR) \
			PublicSubnet2Cidr=$(PUBLIC_SUBNET_2_CIDR) \
			PrivateSubnet1Cidr=$(PRIVATE_SUBNET_1_CIDR) \
			PrivateSubnet2Cidr=$(PRIVATE_SUBNET_2_CIDR)

deploy-ecr:
	$(DEPLOY) \
		--template-file templates/ecr.yaml \
		--stack-name $(STACK_NAME_PREFIX)-ecr \
		--parameter-overrides Environment=$(ENVIRONMENT)

deploy-ecs-cluster:
	$(DEPLOY) \
		--template-file templates/ecs-cluster.yaml \
		--stack-name $(STACK_NAME_PREFIX)-ecs-cluster \
		--parameter-overrides Environment=$(ENVIRONMENT)

deploy-alb:
	$(DEPLOY) \
		--template-file templates/alb.yaml \
		--stack-name $(STACK_NAME_PREFIX)-alb \
		--parameter-overrides Environment=$(ENVIRONMENT)

deploy-rds:
	$(DEPLOY) \
		--template-file templates/rds.yaml \
		--stack-name $(STACK_NAME_PREFIX)-rds \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			DbInstanceClass=$(DB_INSTANCE_CLASS) \
			DbAllocatedStorage=$(DB_ALLOCATED_STORAGE) \
			DbEngineVersion=$(DB_ENGINE_VERSION) \
			DbName=$(DB_NAME) \
			DbMultiAz=$(DB_MULTI_AZ) \
			DbBackupRetentionDays=$(DB_BACKUP_RETENTION_DAYS)

# Depends on deploy-alb (imports its ALB ARN). Ongoing AWS cost - see
# templates/waf.yaml.
deploy-waf:
	$(DEPLOY) \
		--template-file templates/waf.yaml \
		--stack-name $(STACK_NAME_PREFIX)-waf \
		--parameter-overrides Environment=$(ENVIRONMENT)

deploy-service-clients-service:
	$(DEPLOY) \
		--template-file templates/service-clients-service.yaml \
		--stack-name $(STACK_NAME_PREFIX)-clients-service \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			ContainerPort=$(CLIENTS_SERVICE_CONTAINER_PORT) \
			Cpu=$(CLIENTS_SERVICE_CPU) \
			Memory=$(CLIENTS_SERVICE_MEMORY) \
			DesiredCount=$(CLIENTS_SERVICE_DESIRED_COUNT) \
			ImageTag=$(CLIENTS_SERVICE_IMAGE_TAG) \
			MinCapacity=$(CLIENTS_SERVICE_MIN_CAPACITY) \
			MaxCapacity=$(CLIENTS_SERVICE_MAX_CAPACITY)

deploy-service-clients-front:
	$(DEPLOY) \
		--template-file templates/service-clients-front.yaml \
		--stack-name $(STACK_NAME_PREFIX)-clients-front \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			ContainerPort=$(CLIENTS_FRONT_CONTAINER_PORT) \
			Cpu=$(CLIENTS_FRONT_CPU) \
			Memory=$(CLIENTS_FRONT_MEMORY) \
			DesiredCount=$(CLIENTS_FRONT_DESIRED_COUNT) \
			HealthCheckPath=$(CLIENTS_FRONT_HEALTH_CHECK_PATH) \
			ImageTag=$(CLIENTS_FRONT_IMAGE_TAG) \
			MinCapacity=$(CLIENTS_FRONT_MIN_CAPACITY) \
			MaxCapacity=$(CLIENTS_FRONT_MAX_CAPACITY)

# Platform-only stacks: no app image lives in these, so re-running them never
# touches a running ECS service's task definition. Safe to auto-deploy on any
# infra push - this is what deploy-infra.yml's CI job runs. deploy-alerting
# runs first since rds/waf/service stacks import its SNS topic/ALB ARN.
deploy-platform: deploy-alerting deploy-network deploy-ecr deploy-ecs-cluster deploy-alb deploy-waf deploy-rds

# Service stacks own the ECS Service + TaskDefinition that each app's own
# deploy.yml also drives via `aws ecs update-service --force-new-deployment`.
# Deliberately NOT run by CI on every infra push (see deploy-infra.yml) -
# doing so would race the app repos' own deploys of the same ECS service.
# Run by hand (first bootstrap, or a deliberate task-level change like
# Cpu/Memory/DesiredCount) after checking no app deploy is in flight.
deploy-all-services: deploy-service-clients-service deploy-service-clients-front

deploy-all: deploy-platform deploy-all-services
