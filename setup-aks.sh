#!/usr/bin/env bash
# Sets up the voting app on the AKS cluster from infra-aks: platform first, then the app.
# The AKS twin of setup-cluster.sh (EKS); the app manifests in k8s/app/ are shared.
# Run after the cluster exists and kubectl points at it:
#   cd ~/ironhack/infra-aks/cluster && terraform apply && $(terraform output -raw get_credentials)
#   cd ~/ironhack/ironhack-project-2 && ./setup-aks.sh
# Safe to run again: every step checks or updates instead of failing.
#
# Differences from EKS (setup-cluster.sh):
#   - storage:   managed-csi-zrs (Azure zone-redundant disks) instead of gp3 (EBS)
#   - DNS:       one A record in the Azure DNS zone, written here with az (no external-dns)
#   - TLS:       Let's Encrypt HTTP-01 through the Gateway (no cloud permissions needed)
#   - password:  generated once with openssl (no Secrets Manager)
#   - no pipeline access: GitHub Actions still deploys to EKS only
set -euo pipefail

CLUSTER="aks-evgenia-k8s-dev"
NAMESPACE="voting-app"
DNS_RG="rg-evgenia-dns"
DNS_ZONE="aks.springlaughing.dev"
DNS_NAME="vote"                              # -> vote.aks.springlaughing.dev
GATEWAY_API_VERSION="v1.2.1"                 # same versions as Project 2 on EKS,
NGF_CHART_VERSION="1.5.1"                    # so results stay comparable
CERT_MANAGER_CHART_VERSION="v1.21.3"
STORAGE_CLASS="managed-csi-zrs"              # k8s/aks/storageclass.yaml

cd "$(dirname "$0")"
log() { echo; echo "==> $*"; }

for tool in az kubectl helm openssl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# 0. Never run this against the EKS cluster by accident
log "Checking kubectl points at ${CLUSTER}"
CONTEXT=$(kubectl config current-context)
[ "$CONTEXT" = "$CLUSTER" ] || { echo "  current context is '$CONTEXT', not ${CLUSTER}. Stopping."; exit 1; }
kubectl get nodes -L topology.kubernetes.io/zone

# 1. Gateway API CRDs, then NGINX Gateway Fabric. No annotations needed: on AKS a
#    Service of type LoadBalancer gets a public IP on the cluster's Azure load balancer.
log "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing NGINX Gateway Fabric ${NGF_CHART_VERSION} (public IP on the Azure load balancer)"
helm upgrade --install nginx-gateway oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric \
  --version "$NGF_CHART_VERSION" \
  --namespace nginx-gateway --create-namespace \
  --wait --timeout=5m
kubectl get gatewayclass

# 2. cert-manager, after the Gateway API CRDs (it only watches Gateway objects if they
#    exist when it starts).
log "Installing cert-manager ${CERT_MANAGER_CHART_VERSION} (HTTP-01 through the Gateway)"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_CHART_VERSION" \
  --namespace cert-manager --create-namespace \
  -f k8s/aks/cert-manager-values.yaml \
  --wait --timeout=5m


# 3. Platform manifests: shared namespace, AKS-specific storage, Gateway and issuers
log "Applying platform manifests"
kubectl apply -f k8s/platform/namespace.yaml
kubectl apply -f k8s/aks/storageclass.yaml
kubectl apply -f k8s/aks/gateway.yaml
for _ in $(seq 1 12); do                     # cert-manager's webhook may need a few seconds
  kubectl apply -f k8s/aks/cluster-issuers.yaml && break
  echo "  cert-manager webhook not ready yet, retrying in 5 s"
  sleep 5
done

# 4. The database password: generated once. If the Secret exists, keep it: PostgreSQL
#    writes the password into its volume on the first start, a new one would lock us out.
log "Secret db-credentials"
if kubectl get secret db-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "  already there, kept"
else
  PG=$(openssl rand -base64 24 | tr -d '/+=')
  kubectl create secret generic db-credentials -n "$NAMESPACE" \
    --from-literal=username=postgres --from-literal=password="$PG" >/dev/null
  unset PG
  echo "  created (random password, never printed)"
fi

# 5. The app: the same files as on EKS, with two AKS changes made on the way in:
#    gp3 -> the Azure storage class, and no external-dns annotation (no external-dns here).
#    The files in k8s/app/ stay unchanged, so the EKS pipeline keeps working.
log "Applying the app (k8s/app/ with storageClassName ${STORAGE_CLASS})"
for f in k8s/app/*.yaml; do
  sed -e "s/storageClassName: gp3/storageClassName: ${STORAGE_CLASS}/" \
      -e '/external-dns.kubernetes.io\/hostname/d' "$f"
  printf '\n---\n'                           # some files end without a newline
done | kubectl apply -f -
kubectl rollout status deployment/redis    -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=5m
kubectl rollout status statefulset/worker  -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/vote     -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/result   -n "$NAMESPACE" --timeout=5m
kubectl get pvc -n "$NAMESPACE"


# 6. The Gateway's public IP, and vote.aks.springlaughing.dev pointing at it.
#    Replaced on every run: a new cluster means a new IP.
log "Waiting for the Gateway's address"
GW=""
for _ in $(seq 1 30); do
  GW=$(kubectl get gateway voting-gateway -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [ -n "$GW" ] && break
  sleep 10
done
[ -n "$GW" ] || { echo "  no Gateway address after 5 minutes: kubectl describe gateway voting-gateway -n ${NAMESPACE}"; exit 1; }
echo "  Gateway IP: ${GW}"

log "DNS: ${DNS_NAME}.${DNS_ZONE} -> ${GW}"
az network dns record-set a delete -g "$DNS_RG" -z "$DNS_ZONE" -n "$DNS_NAME" --yes >/dev/null 2>&1 || true
az network dns record-set a add-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$DNS_NAME" -a "$GW" --ttl 60 >/dev/null
az network dns record-set a show -g "$DNS_RG" -z "$DNS_ZONE" -n "$DNS_NAME" \
  --query "{name:fqdn, ttl:TTL, ip:ARecords[0].ipv4Address}" -o table

# 7. The certificate. After the DNS record: Let's Encrypt must reach the name over port 80.
#    Not fatal: the app works over HTTP meanwhile.
log "Requesting the certificate for ${DNS_NAME}.${DNS_ZONE}"
kubectl apply -f k8s/aks/certificate.yaml
kubectl wait certificate/voting-tls -n "$NAMESPACE" --for=condition=Ready --timeout=5m \
  || echo "  WARNING: certificate not ready yet; check: kubectl describe certificate voting-tls -n ${NAMESPACE}; kubectl get challenges -n ${NAMESPACE}"

echo "  Vote:   http://${DNS_NAME}.${DNS_ZONE}/   (and https:// once the certificate is ready)"
echo "  Result: http://${DNS_NAME}.${DNS_ZONE}/result/"

# 8. Pages through the Gateway, plus one vote all the way to PostgreSQL
log "Smoke test"
./smoke-test.sh