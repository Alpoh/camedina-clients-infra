include config/dev.env
export

STACK_NAME_PREFIX = $(STACK_PREFIX)-$(ENVIRONMENT)
DEPLOY = aws cloudformation deploy --region $(AWS_REGION) --capabilities CAPABILITY_NAMED_IAM

.PHONY: deploy-network deploy-ecr deploy-ecs-cluster deploy-alb deploy-rds \
        deploy-service-clients-service deploy-service-clients-front deploy-all \
        validate

validate:
	for f in templates/*.yaml; do \
		echo "Validating $$f"; \
		aws cloudformation validate-template --region $(AWS_REGION) --template-body file://$$f > /dev/null; \
	done

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

deploy-service-clients-service:
	$(DEPLOY) \
		--template-file templates/service-clients-service.yaml \
		--stack-name $(STACK_NAME_PREFIX)-clients-service \
		--parameter-overrides Environment=$(ENVIRONMENT) \
			ContainerPort=$(CLIENTS_SERVICE_CONTAINER_PORT) \
			Cpu=$(CLIENTS_SERVICE_CPU) \
			Memory=$(CLIENTS_SERVICE_MEMORY) \
			DesiredCount=$(CLIENTS_SERVICE_DESIRED_COUNT) \
			HealthCheckPath=$(CLIENTS_SERVICE_HEALTH_CHECK_PATH) \
			ImageTag=$(CLIENTS_SERVICE_IMAGE_TAG)

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
			ImageTag=$(CLIENTS_FRONT_IMAGE_TAG)

deploy-all: deploy-network deploy-ecr deploy-ecs-cluster deploy-alb deploy-rds \
	deploy-service-clients-service deploy-service-clients-front
