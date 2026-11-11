# Lets GitHub Actions work in this AWS account WITHOUT storing any access keys in GitHub.
# How it works (OIDC):
#   1. A workflow run asks GitHub for a short-lived signed token that says "I am repo X, environment Y".
#   2. AWS checks the signature and the repo and environment against a trust policy below.
#   3. AWS hands back temporary credentials for that role.
#
# Two roles, because the two jobs need very different power:
#   deploy role   used by the au, uk and us environments   runs Terraform
#   publish role  used by the build environment            may only push images to the cm-* registries

variable "github_repo" {
  description = "owner/name of the repository allowed to deploy"
  type        = string
  default     = "sabiut/case-manager-platform"
}

# The account already trusts GitHub as an identity provider (one per account), so look it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # Builds a trust policy that accepts only the named GitHub environments of this repository.
  # Pull requests, forks and any other workflow get no AWS access at all.
  # Restricting those environments to the main branch is done in the GitHub repository settings.
  trust = { for role, environments in {
    deploy  = ["au", "uk", "us"]
    publish = ["build"]
    } : role => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [
              for env in environments : "repo:${var.github_repo}:environment:${env}"
            ]
          }
        }
      }]
  }) }
}

# ---- Deploy role ----

resource "aws_iam_role" "github_actions" {
  name                 = "cm-platform-github-actions"
  max_session_duration = 7200 # two hours: a SQL Server database can take a long time to create
  assume_role_policy   = local.trust["deploy"]
}

# Lab shortcut: Terraform creates VPCs, IAM roles, RDS, ECS, EKS and more, so this role is admin.
# Production replaces this with a policy listing only what the pipeline needs.
resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---- Publish role ----

resource "aws_iam_role" "github_publish" {
  name               = "cm-platform-github-publish"
  assume_role_policy = local.trust["publish"]
}

resource "aws_iam_role_policy" "github_publish" {
  name = "push-images"
  role = aws_iam_role.github_publish.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SignInToRegistry"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # this action cannot be limited to one repository
      },
      {
        Sid    = "PushToLabRepositoriesOnly"
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/cm-*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "github_publish_role_arn" {
  value = aws_iam_role.github_publish.arn
}
