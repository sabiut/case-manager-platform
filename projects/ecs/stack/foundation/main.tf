# FOUNDATION layer: the slow, long-lived parts of a region. Created once, changed rarely.
#   network + database + image registry
# It has its own state file, so deploying or destroying the app layer can never touch the data.

locals {
  name = "cm-ecs-${var.region_code}"
}

module "network" {
  source = "../../../../modules/network"
  name   = local.name
  cidr   = var.cidr
}

module "database" {
  source         = "../../../../modules/database"
  name           = local.name
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.database_subnet_ids
  engine         = var.db_engine
  instance_class = var.db_instance_class
  multi_az       = var.db_multi_az
}

module "registry" {
  source = "../../../../modules/registry"
  name   = local.name
}
