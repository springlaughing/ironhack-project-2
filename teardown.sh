#!/usr/bin/env bash
# Removes everything Kubernetes created in AWS, before ./down.sh deletes the cluster.
# Terraform (down.sh) doesn't know about the EBS volumes and the NLB: Kubernetes made
# them. Left behind, the volumes keep costing money and the NLB blocks deleting the VPC.
#   cd ~/ironhack/ironhack-project-2  && ./teardown.sh evgenia
#   cd ~/ironhack/eks-quick-terraform && ./down.sh evgenia
set -euo pipefail

NAME="${1:-evgenia}"
CLUSTER="eks-${NAME}"
REGION="us-east-1"
NAMESPACE="voting-app"

log() { echo; echo "==> $*"; }

log "Checking kubectl points at ${CLUSTER}"
CONTEXT=$(kubectl config current-context)
case "$CONTEXT" in
  *"$CLUSTER"*) echo "  current context: $CONTEXT" ;;
  *) echo "  current context is '$CONTEXT', not ${CLUSTER}. Stopping."; exit 1 ;;
esac

# 1. The app namespace: Deployments, StatefulSet, Services, Gateway, HTTPRoute, Secret, PVCs.
#    Deleting the PVCs makes the EBS driver delete the volumes (reclaimPolicy: Delete).
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

# 2. NGINX Gateway Fabric. The NLB belongs to its LoadBalancer Service, so uninstalling
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

# Later issues add their steps here:
#   #11 helm uninstall external-dns and cert-manager (after the namespace, so
#       external-dns can still delete the DNS records)

# Kept on purpose: the Secrets Manager secret, the Route 53 zone, the IAM roles.
log "Done. Now: cd ~/ironhack/eks-quick-terraform && ./down.sh ${NAME}"
