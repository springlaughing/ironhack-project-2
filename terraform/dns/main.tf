# The DNS zone for the voting app: k8s.springlaughing.dev in Route 53.
# Its own Terraform folder and state, separate from the cluster: the zone lives
# for the whole project, the cluster only for a day. down.sh never touches it.
#   cd terraform/dns && terraform init && terraform apply
# Then add the 4 name servers from the output as NS records for "k8s" at Porkbun.

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
  region = "us-east-1" # Route 53 is global; the provider still needs a region
}

resource "aws_route53_zone" "k8s" {
  name    = "k8s.springlaughing.dev"
  comment = "Voting app (Ironhack project 2), delegated from Porkbun"

  tags = {
    Owner   = "evgenia"
    Project = "ironhack-project-2"
  }

  lifecycle {
    prevent_destroy = true # deleting it would break the delegation at Porkbun
  }
}

output "name_servers" {
  description = "Add these as NS records for host k8s at Porkbun"
  value       = aws_route53_zone.k8s.name_servers
}

output "zone_id" {
  description = "external-dns and cert-manager (#11) get permissions on this zone only"
  value       = aws_route53_zone.k8s.zone_id
}
