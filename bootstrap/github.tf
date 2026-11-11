# Lets GitHub Actions work in this AWS account WITHOUT storing any access keys in GitHub.
# How it works (OIDC):
#   1. A workflow run asks GitHub for a short-lived signed token that says "I am repo X, environment Y".
#   2. AWS checks the signature and the repo and environment against a trust policy below.
#   3. AWS hands back temporary credentials for that role.
#
# Two roles, because the two jobs need very different power:
#   deploy role   used by the au, uk and us environments   runs Terraform
#   publish role  used by the build environment            may only push images to the cm-* registries

# How GitHub names this repository in the token it signs (the start of the "sub" claim).
# This repository uses GitHub's immutable form, which carries the owner's and the repository's
# numeric IDs next to their names:  repo:<owner>@<owner id>/<repository>@<repository id>
# The IDs never change and are never reused, so if the repository were deleted and someone else
# created one with the same name, their workflows would still be refused.
# To see the value for a repository:  gh api repos/<owner>/<repository>/actions/oidc/customization/sub
variable "github_subject_prefix" {
  description = "Start of the token subject for the repository allowed to deploy"
  type        = string
  default     = "repo:sabiut@8152759/case-manager-platform@1453499202"
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
              for env in environments : "${var.github_subject_prefix}:environment:${env}"
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
          "ecr:BatchGetImage", # docker push reads the image manifest back to confirm it; without this the push ends in 403
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
