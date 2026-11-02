#!/usr/bin/env bash
# Before `terraform destroy` in infra-aks/cluster: removes what Terraform doesn't know about.
# Most of it goes with the cluster anyway: the disks, the load balancer and its public IP
# live in the node resource group, which AKS deletes with the cluster.
# What stays behind is the A record in the DNS zone: the zone lives for weeks, and a record
# pointing at a released IP could be taken over by whoever gets that IP next.
#   cd ~/ironhack/ironhack-project-2 && ./teardown-aks.sh
#   cd ~/ironhack/infra-aks/cluster  && terraform plan -destroy -out destroy.tfplan && terraform apply destroy.tfplan
set -euo pipefail

CLUSTER="aks-evgenia-k8s-dev"
NAMESPACE="voting-app"
DNS_RG="rg-evgenia-dns"
DNS_ZONE="aks.springlaughing.dev"
DNS_NAME="vote"

log() { echo; echo "==> $*"; }

log "Checking kubectl points at ${CLUSTER}"
CONTEXT=$(kubectl config current-context)
[ "$CONTEXT" = "$CLUSTER" ] || { echo "  current context is '$CONTEXT', not ${CLUSTER}. Stopping."; exit 1; }

# Deleting the namespace deletes the PVCs, and the disk driver deletes the Azure disks.
# Not strictly needed before a destroy, but it shows nothing is left behind.
log "Deleting namespace ${NAMESPACE}"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m
for _ in $(seq 1 36); do
  LEFT=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  [ "$LEFT" -eq 0 ] && break
  echo "  ${LEFT} volume(s) left"
  sleep 5
done
kubectl get pv

log "Deleting DNS record ${DNS_NAME}.${DNS_ZONE}"
az network dns record-set a delete -g "$DNS_RG" -z "$DNS_ZONE" -n "$DNS_NAME" --yes
az network dns record-set list -g "$DNS_RG" -z "$DNS_ZONE" --query "[].{name:name, type:type}" -o table

echo
echo "Done. Now: cd ~/ironhack/infra-aks/cluster && terraform plan -destroy -out destroy.tfplan && terraform apply destroy.tfplan"