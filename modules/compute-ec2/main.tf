# Web tier and application tier on EC2 Windows Server with IIS. The database tier is in the foundation layer.
#
#   internet
#     -> public load balancer   (public subnets)
#     -> frontend servers       (web subnets)   tier 1: serves pages, has no database access
#     -> internal load balancer (app subnets)   not reachable from the internet
#     -> backend API servers    (app subnets)   tier 2: the only thing that talks to the database
#     -> RDS SQL Server         (database subnets, foundation layer)   tier 3
#
# Each tier is its own auto scaling group, so the frontend and the API scale and deploy separately.
# This is the shape a .NET Framework application usually runs in.
# Both tiers serve a placeholder page for now: it proves the network path, not a working application.

data "aws_region" "current" {}

# Image IDs differ in every region. AWS publishes the latest one under this name in each region.
data "aws_ssm_parameter" "windows" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

# ---- Security groups, in the order a request travels ----
# No RDP port (3389) is open anywhere. Administrators connect through Systems Manager Session Manager.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public load balancer: open to the internet"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

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
  from_port                    = 80
  to_port                      = 80
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web"
  description = "Frontend servers: reachable only from the public load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-web" }
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# Outbound: Windows updates, Systems Manager, the internal load balancer.
# This does not give the frontend a way into the database: the database only accepts the API's group.
resource "aws_vpc_security_group_egress_rule" "web_out" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "api_alb" {
  name        = "${var.name}-api-alb"
  description = "Internal load balancer: reachable only from the frontend servers"
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
  from_port                    = 80
  to_port                      = 80
}

resource "aws_security_group" "api" {
  name        = "${var.name}-api"
  description = "Backend API servers: reachable only from the internal load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-api" }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_api_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.api_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

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

# internal = true: it gets private addresses only.
resource "aws_lb" "api" {
  name               = "${var.name}-api"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.app_subnet_ids
  security_groups    = [aws_security_group.api_alb.id]
}

locals {
  # The two tiers are built from the same recipe. Only these values differ.
  tiers = {
    web = {
      title           = "Frontend (web tier)"
      subnet_ids      = var.web_subnet_ids
      security_group  = aws_security_group.web.id
      load_balancer   = aws_lb.web.arn
      extra_page_line = "<p>Backend API: http://${aws_lb.api.dns_name}</p>"
    }
    api = {
      title           = "Backend API (application tier)"
      subnet_ids      = var.app_subnet_ids
      security_group  = aws_security_group.api.id
      load_balancer   = aws_lb.api.arn
      extra_page_line = "<p>Database: ${var.db_host}</p>"
    }
  }
}

resource "aws_lb_target_group" "tier" {
  for_each             = local.tiers
  name                 = "${var.name}-${each.key}"
  vpc_id               = var.vpc_id
  port                 = 80
  protocol             = "HTTP"
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener" "tier" {
  for_each          = local.tiers
  load_balancer_arn = each.value.load_balancer
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tier[each.key].arn
  }
}

# ---- IAM: what each server may do ----
# One role per tier, so only the API servers can read the database login.

resource "aws_iam_role" "instance" {
  for_each = local.tiers
  name     = "${var.name}-${each.key}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Session Manager (remote shell without RDP) and Patch Manager (Windows updates).
resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.tiers
  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.instance["api"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.db_secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  for_each = local.tiers
  name     = "${var.name}-${each.key}-instance"
  role     = aws_iam_role.instance[each.key].name
}

# ---- Launch templates: the recipe for one server of each tier ----

locals {
  # Runs once on first boot: install IIS and publish a page that shows which tier and server answered.
  user_data = { for tier, t in local.tiers : tier => <<-EOT
    <powershell>
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools
    $token = Invoke-RestMethod -Method Put -Uri http://169.254.169.254/latest/api/token -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "300" }
    $h     = @{ "X-aws-ec2-metadata-token" = $token }
    $id    = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id -Headers $h
    $az    = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/placement/availability-zone -Headers $h
    $page  = "<h1>Case Manager lab (EC2 Windows, IIS)</h1><h2>${t.title}</h2><p>Server: $id</p><p>Zone: $az</p>${t.extra_page_line}"
    Set-Content -Path C:\inetpub\wwwroot\index.html -Value $page
    </powershell>
  EOT
  }
}

resource "aws_launch_template" "tier" {
  for_each      = local.tiers
  name_prefix   = "${var.name}-${each.key}-"
  image_id      = data.aws_ssm_parameter.windows.value
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data[each.key])

  iam_instance_profile { arn = aws_iam_instance_profile.instance[each.key].arn }

  vpc_security_group_ids = [each.value.security_group]

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 40
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-${each.key}" }
  }

  lifecycle { create_before_destroy = true }
}

# ---- Auto scaling groups: keep the right number of healthy servers running in each tier ----

resource "aws_autoscaling_group" "tier" {
  for_each            = local.tiers
  name                = "${var.name}-${each.key}"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.min_size
  vpc_zone_identifier = each.value.subnet_ids
  target_group_arns   = [aws_lb_target_group.tier[each.key].arn]

  health_check_type         = "ELB" # replace a server when the load balancer says it is unhealthy
  health_check_grace_period = 900   # Windows takes several minutes to boot and install IIS

  launch_template {
    id      = aws_launch_template.tier[each.key].id
    version = aws_launch_template.tier[each.key].latest_version
  }

  # Deploying a new version = changing the launch template. Servers are then replaced a few at a time.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-${each.key}"
    propagate_at_launch = true
  }
}

# Add servers when average CPU stays above 60 percent, remove them when it drops. Each tier scales on its own.
resource "aws_autoscaling_policy" "cpu" {
  for_each               = local.tiers
  name                   = "${var.name}-${each.key}-cpu"
  autoscaling_group_name = aws_autoscaling_group.tier[each.key].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}

# ---- Renames ----
# These resources kept their AWS names but got new names in this code when the servers were split into
# frontend and API. A "moved" block tells Terraform it is the same resource under a new address,
# so a region deployed with the old layout keeps its public load balancer (and its web address)
# instead of having it destroyed and created again. On a region that was never deployed they do nothing.
moved {
  from = aws_lb.this
  to   = aws_lb.web
}

moved {
  from = aws_lb_listener.http
  to   = aws_lb_listener.tier["web"]
}
