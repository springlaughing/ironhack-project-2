#!/usr/bin/env bash
# Sets up a fresh cluster for the voting app: platform first, then the app.
# Run after the cluster exists:
#   cd ~/ironhack/eks-quick-terraform && TF_VAR_desired_nodes=3 ./up.sh evgenia
#   cd ~/ironhack/ironhack-project-2  && ./setup-cluster.sh evgenia
# Safe to run again: every step checks or updates instead of failing.
set -euo pipefail

NAME="${1:-evgenia}"
CLUSTER="eks-${NAME}"
REGION="us-east-1"
NAMESPACE="voting-app"
GATEWAY_API_VERSION="v1.2.1"     # same as the lab (ingress-gateway/setup/04-install-gateway-api.sh)
NGF_CHART_VERSION="1.5.1"        # NGINX Gateway Fabric version the lab installed
DB_SECRET_ID="voting/db-password"
PIPELINE_ROLE="gha-voting-deploy-${NAME}"   # from terraform/iam/ (#7)
PIPELINE_GROUP="voting-deployers"           # Kubernetes group for extra RBAC (k8s/platform/pipeline-rbac.yaml)
EDIT_POLICY="arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

cd "$(dirname "$0")"             # so k8s/... paths work from anywhere
log() { echo; echo "==> $*"; }

for tool in aws kubectl helm; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# 1. kubectl talks to this cluster (up.sh does this too; harmless to repeat)
log "Connecting kubectl to ${CLUSTER}"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" >/dev/null
kubectl get nodes

# 2. Node-to-node traffic on all ports (Problems and fixes 6)
# The node security group only allows node-to-node TCP 1025-65535; Vote and Result
# listen on port 80, so NGINX couldn't reach pods on other nodes. Same fix as the
# lab script setup/00-oidc-iam.sh, step 6. The security group is new after every up.sh.
log "Allowing all traffic between the cluster's nodes"
NODE_SGS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u)
for SG in $NODE_SGS; do
  if aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
       --protocol -1 --source-group "$SG" --no-cli-pager >/dev/null 2>&1; then
    echo "  $SG: rule added"
  else
    echo "  $SG: rule already exists"
  fi
done

# 3. Gateway API: the new object kinds (CRDs), then the controller that acts on them
log "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing NGINX Gateway Fabric ${NGF_CHART_VERSION} (creates an internet-facing NLB)"
helm upgrade --install nginx-gateway oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric \
  --version "$NGF_CHART_VERSION" \
  --namespace nginx-gateway --create-namespace \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
  --wait --timeout=5m
kubectl get gatewayclass

# 4. Platform manifests, in an order that works (kubectl -f <dir> would go
#    alphabetically: gateway.yaml before namespace.yaml, which fails)
log "Applying platform manifests"
kubectl apply -f k8s/platform/namespace.yaml
kubectl apply -f k8s/platform/storageclass.yaml      # before any PVC (Problems and fixes 3)
kubectl apply -f k8s/platform/gateway.yaml

# 5. The database password: from Secrets Manager into a Kubernetes Secret.
#    Never printed, never in a file. "create --dry-run | apply" = create or update.
log "Creating Secret db-credentials from Secrets Manager (${DB_SECRET_ID})"
PG=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$DB_SECRET_ID" \
  --query SecretString --output text)
kubectl create secret generic db-credentials -n "$NAMESPACE" \
  --from-literal=username=postgres --from-literal=password="$PG" \
  --dry-run=client -o yaml | kubectl apply -f -
unset PG

# 6. The pipeline's way into the cluster (#7). Its IAM role (terraform/iam/) gets an
#    access entry: edit rights in voting-app only, plus the Kubernetes group
#    voting-deployers for anything edit doesn't cover. The entry lives in the cluster,
#    so it's gone after down.sh and created again here after every up.sh.
log "Giving ${PIPELINE_ROLE} edit rights in ${NAMESPACE} only"
PIPELINE_ROLE_ARN=$(aws iam get-role --role-name "$PIPELINE_ROLE" --query Role.Arn --output text)
if aws eks describe-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
     --principal-arn "$PIPELINE_ROLE_ARN" >/dev/null 2>&1; then
  echo "  access entry already exists"
else
  aws eks create-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
    --principal-arn "$PIPELINE_ROLE_ARN" --kubernetes-groups "$PIPELINE_GROUP" \
    --type STANDARD --no-cli-pager >/dev/null
  echo "  access entry created (group ${PIPELINE_GROUP})"
fi
aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$PIPELINE_ROLE_ARN" --policy-arn "$EDIT_POLICY" \
  --access-scope type=namespace,namespaces="$NAMESPACE" --no-cli-pager >/dev/null
echo "  AmazonEKSEditPolicy, scope: namespace ${NAMESPACE}"

# 7. The app, so it runs before the pipeline's first deploy
log "Applying the app"
kubectl apply -f k8s/app/
kubectl rollout status deployment/redis    -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=5m
kubectl rollout status statefulset/worker  -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/vote     -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/result   -n "$NAMESPACE" --timeout=5m

# Later issues add their steps here:
#   #11 external-dns and cert-manager with their Pod Identity associations, ClusterIssuer

# 8. Where to find it. A new NLB's DNS name can take a few minutes to work.
log "Waiting for the Gateway's address"
GW=""
for _ in $(seq 1 30); do
  GW=$(kubectl get gateway voting-gateway -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [ -n "$GW" ] && break
  sleep 10
done
echo "  Vote:   http://${GW}/vote"
echo "  Result: http://${GW}/result"

# 9. Does it really work? Pages through the Gateway, plus one vote all the way to PostgreSQL.
#    Waits for a new NLB's DNS by itself.
log "Smoke test"
./smoke-test.sh