# Web tier and application tier on ECS Fargate. The database tier is in the foundation layer.
#
#   internet
#     -> public load balancer   (public subnets)
#     -> frontend containers    (web subnets)   tier 1: serves pages, has no database access
#     -> internal load balancer (app subnets)   not reachable from the internet
#     -> backend API containers (app subnets)   tier 2: the only thing that talks to the database
#     -> RDS SQL Server         (database subnets, foundation layer)   tier 3
#
# Each arrow is one security group rule. Nothing can skip a tier:
# the internet cannot reach the API, and the frontend cannot reach the database.

data "aws_region" "current" {}

locals {
  placeholder = "public.ecr.aws/nginx/nginx:stable"
  web_image   = var.web_image != "" ? var.web_image : local.placeholder
  api_image   = var.api_image != "" ? var.api_image : local.placeholder
}

# ---- Security groups, in the order a request travels ----

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public load balancer: open to the internet"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

# Lab uses plain HTTP because there is no domain name. Production listens on 443 with an ACM certificate.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web"
  description = "Frontend: reachable only from the public load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-web" }
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

# Outbound: pull the image, write logs, call the internal load balancer.
# This does not give the frontend a way into the database: the database only accepts the API's group.
resource "aws_vpc_security_group_egress_rule" "web_out" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "api_alb" {
  name        = "${var.name}-api-alb"
  description = "Internal load balancer: reachable only from the frontend"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-api-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "api_alb_from_web" {
  security_group_id            = aws_security_group.api_alb.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "api_alb_to_api" {
  security_group_id            = aws_security_group.api_alb.id
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_security_group" "api" {
  name        = "${var.name}-api"
  description = "Backend API: reachable only from the internal load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-api" }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_api_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.api_alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

# Outbound: pull the image, write logs, read the secret, reach the database.
resource "aws_vpc_security_group_egress_rule" "api_out" {
  security_group_id = aws_security_group.api.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- Load balancers ----

resource "aws_lb" "web" {
  name               = var.name
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name}-web"
  vpc_id      = var.vpc_id
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip" # Fargate tasks register by IP address

  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# internal = true: it gets private addresses only and has no public DNS record that resolves from outside.
resource "aws_lb" "api" {
  name               = "${var.name}-api"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.app_subnet_ids
  security_groups    = [aws_security_group.api_alb.id]
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api"
  vpc_id      = var.vpc_id
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ---- IAM roles (IAM is global: var.name carries the region code so names never clash) ----
# Each service has its own pair of roles, so the frontend cannot read the database secrets.
#   execution role: used by ECS itself to pull the image, write logs and fetch secrets
#   task role:      what the application code itself may do in AWS (nothing yet)

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web_execution" {
  name               = "${var.name}-web-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "web_execution" {
  role       = aws_iam_role.web_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "web_task" {
  name               = "${var.name}-web-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role" "api_execution" {
  name               = "${var.name}-api-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "api_execution" {
  role       = aws_iam_role.api_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.api_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.app_db_secret_arn, var.admin_db_secret_arn]
    }]
  })
}

resource "aws_iam_role" "api_task" {
  name               = "${var.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ---- ECS ----

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/app"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Tier 1: frontend. Knows the address of the API and nothing about the database.
resource "aws_ecs_task_definition" "web" {
  family                   = "${var.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.web_execution.arn
  task_role_arn            = aws_iam_role.web_task.arn

  container_definitions = jsonencode([{
    name      = "web"
    image     = local.web_image
    essential = true

    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    environment = [
      { name = "API_URL", value = "http://${aws_lb.api.dns_name}" },
      { name = "REGION_CODE", value = var.region_code }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "web"
      }
    }
  }])
}

# Tier 2: backend API.
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.api_execution.arn
  task_role_arn            = aws_iam_role.api_task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = local.api_image
    essential = true

    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    environment = [
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_NAME", value = var.db_name },
      { name = "REGION_CODE", value = var.region_code }
    ]

    # The restricted login. The password is never in the task definition, only a pointer to the secret.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.app_db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.app_db_secret_arn}:password::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

# One-off task that prepares the database: the API image, a different command, the admin login.
# The pipeline runs it once per deployment, BEFORE the services are updated. It is not part of a service.
resource "aws_ecs_task_definition" "migrate" {
  count = var.api_image != "" ? 1 : 0 # the placeholder web server has nothing to migrate

  # Everything the task needs in order to run. The pipeline creates this resource first, on its own
  # (terraform apply -target), and these dependencies make sure the pieces below exist by then:
  # a cluster to run in, permission to read the secrets, and a way out to the registry and the logs.
  depends_on = [
    aws_ecs_cluster.this,
    aws_iam_role_policy_attachment.api_execution,
    aws_iam_role_policy.read_db_secret,
    aws_vpc_security_group_egress_rule.api_out,
  ]

  family                   = "${var.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.api_execution.arn
  task_role_arn            = aws_iam_role.api_task.arn

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = local.api_image
    essential = true
    command   = ["python", "migrate.py"]

    environment = [
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_NAME", value = var.db_name }
    ]

    secrets = [
      { name = "DB_ADMIN_USER", valueFrom = "${var.admin_db_secret_arn}:username::" },
      { name = "DB_ADMIN_PASSWORD", valueFrom = "${var.admin_db_secret_arn}:password::" },
      { name = "APP_DB_USER", valueFrom = "${var.app_db_secret_arn}:username::" },
      { name = "APP_DB_PASSWORD", valueFrom = "${var.app_db_secret_arn}:password::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "migrate"
      }
    }
  }])
}

resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.container_port
  }

  # Zero-downtime rolling deploy: start new copies before stopping old ones.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # If the new version never becomes healthy, go back to the previous one automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # "terraform apply" does not return until the deployment has finished (or failed),
  # instead of returning as soon as ECS has accepted the request.
  wait_for_steady_state = true

  depends_on = [aws_lb_listener.api]
}

resource "aws_ecs_service" "web" {
  name            = "web"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.web_subnet_ids
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  wait_for_steady_state = true

  # The API is rolled out first and must be stable before the frontend that calls it is updated.
  # So within one release: database migration, then API, then frontend.
  depends_on = [aws_lb_listener.web, aws_ecs_service.api]
}
