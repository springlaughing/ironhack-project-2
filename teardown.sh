#!/usr/bin/env bash
# Removes everything Kubernetes created in AWS, before ./down.sh deletes the cluster.
# Terraform (down.sh) doesn't know about the EBS volumes, the NLB and the DNS records:
# Kubernetes made them. Left behind, the volumes keep costing money, the NLB blocks
# deleting the VPC, and the DNS records point at an NLB that no longer exists.
#   cd ~/ironhack/ironhack-project-2  && ./teardown.sh evgenia
#   cd ~/ironhack/eks-quick-terraform && ./down.sh evgenia
set -euo pipefail

NAME="${1:-evgenia}"
CLUSTER="eks-${NAME}"
REGION="us-east-1"
NAMESPACE="voting-app"
DOMAIN="k8s.springlaughing.dev"

log() { echo; echo "==> $*"; }

log "Checking kubectl points at ${CLUSTER}"
CONTEXT=$(kubectl config current-context)
case "$CONTEXT" in
  *"$CLUSTER"*) echo "  current context: $CONTEXT" ;;
  *) echo "  current context is '$CONTEXT', not ${CLUSTER}. Stopping."; exit 1 ;;
esac

# 1. The app namespace: Deployments, StatefulSet, Services, Gateway, HTTPRoute, Secret, PVCs.
#    Deleting the PVCs makes the EBS driver delete the volumes (reclaimPolicy: Delete).
#    Deleting the HTTPRoute tells external-dns to delete the DNS records (step 2).
log "Deleting namespace ${NAMESPACE}"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m

# The volumes are deleted a little after their PVCs: wait until no PersistentVolume is left,
# while the EBS driver still exists to do it.
log "Waiting for the EBS volumes to be deleted"
for _ in $(seq 1 36); do
  LEFT=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  [ "$LEFT" -eq 0 ] && break
  echo "  ${LEFT} volume(s) left"
  sleep 5
done
kubectl get pv

# 2. external-dns (#11). The HTTPRoute is gone, so on its next cycle (every minute)
#    external-dns deletes the A, AAAA and TXT records it owns. Wait until Route 53 really
#    has none left, THEN uninstall it: uninstalled first, nobody would delete them.
log "Waiting for external-dns to delete the DNS records of ${DOMAIN}"
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')
RECORDS=-1
for _ in $(seq 1 36); do
  RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "length(ResourceRecordSets[?Type=='A' || Type=='AAAA' || Type=='TXT'])" --output text)
  [ "$RECORDS" = "0" ] && { echo "  records deleted (only NS and SOA left)"; break; }
  echo "  ${RECORDS} record(s) left"
  sleep 5
done
if [ "$RECORDS" != "0" ]; then
  echo "  WARNING: records still in zone ${ZONE_ID} after 3 minutes (is external-dns running?):"
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query 'ResourceRecordSets[].[Name,Type]' --output text
fi

log "Uninstalling external-dns"
helm uninstall external-dns -n external-dns --wait 2>/dev/null || echo "  not installed"
kubectl delete namespace external-dns --ignore-not-found --wait=true --timeout=2m

# 3. NGINX Gateway Fabric. The NLB belongs to its LoadBalancer Service, so uninstalling
#    it makes AWS delete the NLB. Remember the NLB's name first, to wait for it.
log "Uninstalling NGINX Gateway Fabric (and with it the NLB)"
LB_DNS=$(kubectl get svc -n nginx-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
helm uninstall nginx-gateway -n nginx-gateway --wait 2>/dev/null || echo "  not installed"

if [ -n "$LB_DNS" ]; then
  echo "  waiting for ${LB_DNS%%.*} to disappear"
  for _ in $(seq 1 36); do
    COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?DNSName=='${LB_DNS}'])" --output text)
    [ "$COUNT" = "0" ] && { echo "  NLB deleted"; break; }
    sleep 5
  done
fi

# 4. cert-manager (#11). The certificate and its Secret went with the app namespace (step 1).
#    The ClusterIssuers belong to no namespace: delete them while cert-manager still exists.
#    Its Route 53 access is only for TXT _acme-challenge records during a renewal; none is
#    running now, so nothing is left in the zone.
log "Uninstalling cert-manager"
kubectl delete -f k8s/platform/cluster-issuers.yaml --ignore-not-found
helm uninstall cert-manager -n cert-manager --wait 2>/dev/null || echo "  not installed"
kubectl delete namespace cert-manager --ignore-not-found --wait=true --timeout=2m

# Kept on purpose: the Secrets Manager secret, the Route 53 zone (with its NS and SOA),
# the IAM roles. The Pod Identity associations belong to the cluster and go with down.sh.
log "Done. Now: cd ~/ironhack/eks-quick-terraform && ./down.sh ${NAME}"
