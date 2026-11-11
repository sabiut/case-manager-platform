# Lets GitHub Actions deploy to this AWS account WITHOUT storing any access keys in GitHub.
# How it works (OIDC):
#   1. A workflow run asks GitHub for a short-lived signed token that says "I am repo X".
#   2. AWS checks the signature and the repo name against the trust policy below.
#   3. AWS hands back temporary credentials for this role, valid for one hour.

variable "github_repo" {
  description = "owner/name of the repository allowed to deploy"
  type        = string
  default     = "sabiut/case-manager-platform"
}

# The account already trusts GitHub as an identity provider (one per account), so look it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name                 = "cm-platform-github-actions"
  max_session_duration = 7200 # two hours: a SQL Server database can take a long time to create

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Only deploy jobs that run in the au, uk or us environment of this repository.
          # Pull requests, forks and any other workflow get no AWS access at all.
          "token.actions.githubusercontent.com:sub" = [
            for env in ["au", "uk", "us"] : "repo:${var.github_repo}:environment:${env}"
          ]
        }
      }
    }]
  })
}

# Lab shortcut: Terraform creates VPCs, IAM roles, RDS, ECS, EKS and more, so the role is admin.
# Production replaces this with a policy listing only what the pipeline needs.
resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
