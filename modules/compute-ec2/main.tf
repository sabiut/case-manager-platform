# Web tier + app tier on EC2 Windows Server with IIS:
#   internet -> load balancer (public subnets) -> Windows servers in an auto scaling group (private subnets)
# This is the shape a .NET Framework application usually runs in.

data "aws_region" "current" {}

# Image IDs differ in every region. AWS publishes the latest one under this name in each region.
data "aws_ssm_parameter" "windows" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

# ---- Security groups ----

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Load balancer: open to the internet"
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

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# No RDP port (3389) is open. Administrators connect through Systems Manager Session Manager instead.
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "App tier: reachable only from the load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- Load balancer ----

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name                 = var.name
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---- IAM: what each server may do ----

resource "aws_iam_role" "instance" {
  name = "${var.name}-instance"
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
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.instance.id
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
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

# ---- Launch template: the recipe for one server ----

locals {
  # Runs once on first boot: install IIS and publish a page that shows which server answered.
  user_data = <<-EOT
    <powershell>
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools
    $token = Invoke-RestMethod -Method Put -Uri http://169.254.169.254/latest/api/token -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "300" }
    $h     = @{ "X-aws-ec2-metadata-token" = $token }
    $id    = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id -Headers $h
    $az    = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/placement/availability-zone -Headers $h
    $page  = "<h1>Case Manager lab (EC2 Windows, IIS)</h1><p>Server: $id</p><p>Zone: $az</p><p>Database: ${var.db_host}</p>"
    Set-Content -Path C:\inetpub\wwwroot\index.html -Value $page
    </powershell>
  EOT
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.windows.value
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data)

  iam_instance_profile { arn = aws_iam_instance_profile.instance.arn }

  vpc_security_group_ids = [aws_security_group.app.id]

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
    tags          = { Name = var.name }
  }

  lifecycle { create_before_destroy = true }
}

# ---- Auto scaling group: keeps the right number of healthy servers running ----

resource "aws_autoscaling_group" "app" {
  name                = var.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.min_size
  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  health_check_type         = "ELB" # replace a server when the load balancer says it is unhealthy
  health_check_grace_period = 900   # Windows takes several minutes to boot and install IIS

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
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
    value               = var.name
    propagate_at_launch = true
  }
}

# Add servers when average CPU stays above 60 percent, remove them when it drops.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}
