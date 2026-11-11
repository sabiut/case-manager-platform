# Data tier: one SQL Server instance for the region.
# Each customer gets their own database inside it (created later with sqlcmd, not Terraform).

data "aws_caller_identity" "current" {}

# The major version is pinned (var.major_version). Within it, take the newest patch release,
# so regions do not end up on different SQL Server generations depending on the day they were built.
data "aws_rds_engine_version" "this" {
  engine  = var.engine
  version = var.major_version
  latest  = true
}

locals {
  # "16.00.4165.4.v1" -> "16.00". The option group needs the major version.
  major_version = join(".", slice(split(".", data.aws_rds_engine_version.this.version), 0, 2))
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

# Starts with no inbound rules. The stack adds one rule: port 1433 from the app tier only.
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Database tier"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db" }
}

# ---- Native backup and restore through S3 (used for customer migrations) ----

resource "aws_s3_bucket" "migration" {
  bucket        = "${var.name}-migration-${data.aws_caller_identity.current.account_id}"
  force_destroy = !var.protect_data
}

resource "aws_s3_bucket_server_side_encryption_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "migration" {
  bucket                  = aws_s3_bucket.migration.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Backup files are full copies of customer data: delete them automatically after 14 days.
resource "aws_s3_bucket_lifecycle_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    id     = "expire-backups"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
  }
}

# The role the database server uses to read and write the migration bucket.
# IAM is global, so the name carries the region code through var.name.
resource "aws_iam_role" "rds_s3" {
  name = "${var.name}-rds-backup-restore"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_s3" {
  name = "migration-bucket"
  role = aws_iam_role.rds_s3.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.migration.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.migration.arn}/*"
      }
    ]
  })
}

# Switches on msdb.dbo.rds_restore_database and rds_backup_database.
resource "aws_db_option_group" "this" {
  name                 = var.name
  engine_name          = var.engine
  major_engine_version = local.major_version

  option {
    option_name = "SQLSERVER_BACKUP_RESTORE"
    option_settings {
      name  = "IAM_ROLE_ARN"
      value = aws_iam_role.rds_s3.arn
    }
  }
}

# ---- The database server ----

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = var.engine
  engine_version = data.aws_rds_engine_version.this.version
  license_model  = "license-included"
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  username                    = "cmadmin"
  manage_master_user_password = true # AWS creates the password and keeps it in Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  option_group_name      = aws_db_option_group.this.name

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true # patch releases only, inside the pinned major version

  deletion_protection       = var.protect_data
  skip_final_snapshot       = !var.protect_data
  final_snapshot_identifier = var.protect_data ? "${var.name}-final" : null
  apply_immediately         = !var.protect_data # real data: changes wait for the maintenance window
}

# ---- The web app's own database login ----
# The app must not use the admin login above. Terraform generates a password for a restricted
# login and stores it here. The migration task creates the login in SQL Server with this password.

resource "random_password" "app" {
  length      = 32
  special     = false # letters and digits only: the value is placed into a CREATE LOGIN statement
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name}/app-db-login"
  description             = "Restricted SQL Server login used by the web app"
  recovery_window_in_days = var.protect_data ? 30 : 0 # lab: delete at once so the name can be reused
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    username = "cm_app"
    password = random_password.app.result
  })
}
