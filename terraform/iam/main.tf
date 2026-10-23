# IAM for the voting app: the role GitHub Actions assumes through OIDC.
# Its own Terraform folder and state, like terraform/dns/: the role lives for the
# whole project, the cluster only for a day. down.sh never touches it.
#   cd terraform/iam && terraform init && terraform apply
# Not here: the EKS access entry for this role. It dies with the cluster,
# so setup-cluster.sh creates it again after every up.sh.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  name    = "evgenia"
  cluster = "eks-evgenia"

  # GitHub's immutable subject for runs on main (gh api .../actions/oidc/customization/sub):
  # names plus numeric IDs, so a new repo that reuses the name can't match.
  github_sub_main = "repo:springlaughing@31309521/ironhack-project-2@1429561780:ref:refs/heads/main"

  tags = {
    Owner   = "evgenia"
    Project = "ironhack-project-2"
  }
}

data "aws_caller_identity" "current" {}

# Created once per account in the lab: read it, never create it a second time.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Created by hand in #1; the ARN ends in a random suffix, so look it up by name.
data "aws_secretsmanager_secret" "db_password" {
  name = "voting/db-password"
}

# Who may take on the role: a GitHub token for this repo's main branch, meant for AWS STS.
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_main]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name                 = "gha-voting-deploy-${local.name}"
  description          = "GitHub Actions, springlaughing/ironhack-project-2 main only, deploys the voting app to ${local.cluster}"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600 # 1 hour, the minimum; a pipeline run takes minutes
  tags                 = local.tags
}

# What the role may do in AWS: find the cluster, read the DB password. Nothing else.
# What it may do inside the cluster is decided by the access entry, not here.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "FindTheCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:us-east-1:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster}"]
  }

  statement {
    sid       = "ReadDbPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.db_password.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-voting-app"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "role_arn" {
  description = "GitHub variable AWS_ROLE_ARN; setup-cluster.sh gives this role its access entry"
  value       = aws_iam_role.gha_deploy.arn
}
