# Pod Identity roles for the two platform controllers of #11.
#   external-dns: writes the A record for k8s.springlaughing.dev into Route 53.
#   cert-manager: writes the TXT record Let's Encrypt checks (DNS-01) to issue the certificate.
# Same folder and state as the pipeline role (main.tf): these roles live for the whole
# project. The Pod Identity associations (role <-> namespace + service account) live in
# the cluster, so setup-cluster.sh creates them after every up.sh.
#
# Why Pod Identity, not IRSA (the lab's way): an IRSA trust policy names the cluster's own
# OIDC provider, whose ID is new after every up.sh, so the role would need rewriting every
# morning. A Pod Identity trust policy names the EKS service and the cluster's ARN, which
# stays the same (eks-evgenia), so these roles survive any number of rebuilds unchanged.

# The zone from terraform/dns/, looked up by name (its own state, so no direct reference).
data "aws_route53_zone" "k8s" {
  name = "k8s.springlaughing.dev"
}

locals {
  cluster_arn = "arn:aws:eks:us-east-1:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster}"
}

# Who may take on these roles: the EKS Pod Identity service, for my cluster only.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.cluster_arn]
    }
  }
}

# ---------- external-dns ----------

resource "aws_iam_role" "external_dns" {
  name               = "external-dns-${local.name}"
  description        = "external-dns in ${local.cluster} (Pod Identity): records in k8s.springlaughing.dev only"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecordsInMyZoneOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.k8s.arn]
  }

  statement {
    sid = "FindZonesAndRecords" # read only; external-dns lists zones, then filters by name
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-k8s-zone"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

# ---------- cert-manager ----------

resource "aws_iam_role" "cert_manager" {
  name               = "cert-manager-${local.name}"
  description        = "cert-manager in ${local.cluster} (Pod Identity): DNS-01 TXT records in k8s.springlaughing.dev only"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid       = "SeeWhetherAChangeIsDone"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid       = "AcmeChallengeTxtRecordsOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.k8s.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.*"]
    }
  }

  statement {
    sid       = "ReadMyZone"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [data.aws_route53_zone.k8s.arn]
  }

  statement {
    sid       = "FindTheZone"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cert_manager" {
  name   = "route53-acme-challenge"
  role   = aws_iam_role.cert_manager.id
  policy = data.aws_iam_policy_document.cert_manager.json
}

output "external_dns_role_arn" {
  description = "setup-cluster.sh: Pod Identity association for external-dns/external-dns"
  value       = aws_iam_role.external_dns.arn
}

output "cert_manager_role_arn" {
  description = "setup-cluster.sh: Pod Identity association for cert-manager/cert-manager"
  value       = aws_iam_role.cert_manager.arn
}
