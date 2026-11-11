# Usage:  make plan P=ecs R=au     (P = project: ecs, ec2, eks   R = region: au, uk, us)
P ?= ecs
R ?= au
DIR = projects/$(P)/$(R)

bootstrap:
	cd bootstrap && terraform init && terraform apply

init:
	cd $(DIR) && terraform init -backend-config=../../../backend.hcl

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
