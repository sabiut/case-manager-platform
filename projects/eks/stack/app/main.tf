# APP layer: Kubernetes cluster + worker nodes. The app itself is deployed with kubectl (k8s/app.yaml).

locals {
  name = "cm-eks-${var.region_code}"
}

# ---- Find what the foundation layer built, by name and tag ----
# The two layers share nothing except these names. If the foundation is missing, plan fails here.

data "aws_vpc" "this" {
  tags = { Name = local.name }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "public" }
}

data "aws_subnets" "app" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "app" }
}

data "aws_db_instance" "this" {
  db_instance_identifier = local.name
}

data "aws_security_group" "db" {
  name   = "${local.name}-db"
  vpc_id = data.aws_vpc.this.id
}

module "app" {
  source            = "../../../../modules/compute-eks"
  name              = local.name
  public_subnet_ids = data.aws_subnets.public.ids
  app_subnet_ids    = data.aws_subnets.app.ids
}

# The only way into the database: SQL Server port, from the worker nodes' security group.
# Inside the cluster, NetworkPolicy rules (k8s/app.yaml) stop the frontend pods from using it.
# The rule belongs to the app layer, so destroying the app also closes the door.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = data.aws_security_group.db.id
  referenced_security_group_id = module.app.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the Kubernetes nodes"
}
