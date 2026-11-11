# The three tiers wired together. The same file builds Australia, the UK and the US.
# Only region_code and cidr change between them.

locals {
  name = "cm-ecs-${var.region_code}"
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
  source            = "../../../modules/compute-ecs"
  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  app_subnet_ids    = module.network.app_subnet_ids
  image             = var.image
  container_port    = var.container_port
  health_check_path = var.health_check_path
  db_host           = module.database.address
  db_secret_arn     = module.database.master_secret_arn
}

# The only way into the database: SQL Server port, from the app tier's security group.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = module.database.security_group_id
  referenced_security_group_id = module.app.app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the app tier"
}
