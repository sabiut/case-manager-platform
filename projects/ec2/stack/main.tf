# The three tiers wired together, with Windows servers as the app tier.

locals {
  name = "cm-ec2-${var.region_code}"
}

module "network" {
  source = "../../../modules/network"
  name   = local.name
  cidr   = var.cidr
}

module "database" {
  source         = "../../../modules/database"
  name           = local.name
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.database_subnet_ids
  engine         = var.db_engine
  instance_class = var.db_instance_class
  multi_az       = var.db_multi_az
}

module "app" {
  source            = "../../../modules/compute-ec2"
  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  app_subnet_ids    = module.network.app_subnet_ids
  db_host           = module.database.address
  db_secret_arn     = module.database.master_secret_arn
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = module.database.security_group_id
  referenced_security_group_id = module.app.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the app tier"
}
