# APP layer: load balancer + Windows servers with IIS. Safe to destroy and rebuild.

locals {
  name = "cm-ec2-${var.region_code}"
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
  source            = "../../../../modules/compute-ec2"
  name              = local.name
  vpc_id            = data.aws_vpc.this.id
  public_subnet_ids = data.aws_subnets.public.ids
  app_subnet_ids    = data.aws_subnets.app.ids
  db_host           = data.aws_db_instance.this.address
  db_secret_arn     = data.aws_db_instance.this.master_user_secret[0].secret_arn
}

# The only way into the database: SQL Server port, from the app tier's security group.
# It belongs to the app layer, so destroying the app also closes the door.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = data.aws_security_group.db.id
  referenced_security_group_id = module.app.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the app tier"
}

# Web application firewall in front of the load balancer.
module "waf" {
  source            = "../../../../modules/waf"
  name              = local.name
  load_balancer_arn = module.app.load_balancer_arn
}
