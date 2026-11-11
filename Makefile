# Usage:  make plan P=ecs R=au L=foundation
#   P = project: ecs, ec2, eks      R = region: au, uk, us      L = layer: foundation, app
# Deploy order: foundation first, then app. Destroy order: app first, then foundation.
P ?= ecs
R ?= au
L ?= foundation
DIR = projects/$(P)/$(R)/$(L)

bootstrap:
	cd bootstrap && terraform init && terraform apply

init:
	cd $(DIR) && terraform init -backend-config=../../../../backend.hcl

plan: init
	cd $(DIR) && terraform plan

apply: init
	cd $(DIR) && terraform apply

destroy: init
	cd $(DIR) && terraform destroy

output:
	cd $(DIR) && terraform output

fmt:
	terraform fmt -recursive

.PHONY: bootstrap init plan apply destroy output fmt
