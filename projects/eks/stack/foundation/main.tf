# FOUNDATION layer: the slow, long-lived parts of a region. Created once, changed rarely.
#   network + database + image registries
# It has its own state file, so deploying or destroying the app layer can never touch the data.

locals {
  name = "cm-eks-${var.region_code}"
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
  protect_data   = var.protect_data
}

# One registry per image: the frontend and the backend API are built and versioned separately.
module "registry_web" {
  source = "../../../../modules/registry"
  name   = "${local.name}-web"
}

module "registry_api" {
  source = "../../../../modules/registry"
  name   = "${local.name}-api"
}

# LEGACY: the single registry from before the app was split into frontend and API.
# A region deployed with the old layout still runs images from it, and a rollback would pull from it,
# so it is kept until that region runs the new frontend and API images.
# Remove this block in a separate, later change, once no region uses the old layout.
module "registry" {
  source = "../../../../modules/registry"
  name   = local.name
}
