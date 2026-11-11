# APP layer: load balancers + frontend and backend API containers. Changes often, safe to destroy and rebuild.

locals {
  name = "cm-ecs-${var.region_code}"
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

data "aws_subnets" "web" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "web" }
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

data "aws_secretsmanager_secret" "app_db" {
  name = "${local.name}/app-db-login"
}

data "aws_ecr_repository" "web" {
  name = "${local.name}-web"
}

data "aws_ecr_repository" "api" {
  name = "${local.name}-api"
}

locals {
  real_app = var.image_tag != ""
}

module "app" {
  source            = "../../../../modules/compute-ecs"
  name              = local.name
  region_code       = var.region_code
  vpc_id            = data.aws_vpc.this.id
  public_subnet_ids = data.aws_subnets.public.ids
  web_subnet_ids    = data.aws_subnets.web.ids
  app_subnet_ids    = data.aws_subnets.app.ids

  # Deploying a version = setting image_tag. Rolling back = setting the previous tag.
  # Both images are built from the same commit, so they share one tag.
  web_image         = local.real_app ? "${data.aws_ecr_repository.web.repository_url}:${var.image_tag}" : ""
  api_image         = local.real_app ? "${data.aws_ecr_repository.api.repository_url}:${var.image_tag}" : ""
  container_port    = local.real_app ? 8080 : 80
  health_check_path = local.real_app ? "/health" : "/"

  db_host             = data.aws_db_instance.this.address
  app_db_secret_arn   = data.aws_secretsmanager_secret.app_db.arn
  admin_db_secret_arn = data.aws_db_instance.this.master_user_secret[0].secret_arn
}

# The only way into the database: SQL Server port, from the backend API's security group.
# The frontend is not on this list, so it cannot connect to the database even if it tried.
# The rule belongs to the app layer, so destroying the app also closes the door.
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = data.aws_security_group.db.id
  referenced_security_group_id = module.app.api_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the backend API"
}

# Web application firewall in front of the public load balancer.
module "waf" {
  source            = "../../../../modules/waf"
  name              = local.name
  load_balancer_arn = module.app.load_balancer_arn
}
