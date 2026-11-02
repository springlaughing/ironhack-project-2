#!/usr/bin/env bash
# Node failure on AKS: a steady stream of votes, and 60 s in, the VM running PostgreSQL
# is switched off (az vmss deallocate). With one node per zone, that is also a zone failure.
#   ./loadtest/node-failure-test.sh N1
# Question: does the app heal itself, does PostgreSQL's ZRS disk follow it into another
# zone, and is every accepted vote saved in the end?
# k6 runs here on the laptop (binary or Docker): the cluster is in Frankfurt, close enough.
# Steps:
#   1. find PostgreSQL's node and its VM in the scale set; note where every pod runs
#   2. delete this run's votes from an earlier try (k6f-<RUN>-...)
#   3. start k6 and the samplers (every 2 s: nodes, pods, Redis queue, saved votes; all events)
#   4. 60 s after k6's start: switch the VM off
#   5. wait for k6, then until the queue is empty and PostgreSQL answers (at most 10 min)
#   6. print: accepted vs saved, and the timeline of what happened
#   7. switch the VM on again
# Everything lands in loadtest/results/<RUN>-*.
# Unlike rollout-test.sh, the samplers run HERE, not inside the pods: the PostgreSQL pod
# is the one that dies, and a sampler inside it would die with it.
set -euo pipefail
cd "$(dirname "$0")/.."
source loadtest/lib-cluster.sh   # spread check

RUN="${1:?usage: node-failure-test.sh <run name, e.g. N1>}"
NS="voting-app"
NODE_RG="${NODE_RG:-rg-evgenia-k8s-dev-nodes}"
K6_SECONDS="${K6_SECONDS:-1200}"   # 20 min of votes: room for eviction (~5 min) + disk detach (~6 min)
FAIL_AFTER="${FAIL_AFTER:-60}"     # when the VM goes off, seconds after k6's start
export RUN RATE="${RATE:-20}" DURATION="${K6_SECONDS}s" TARGET="${TARGET:-https://vote.aks.springlaughing.dev/}" BURST_AT=""

OUT="loadtest/results"
mkdir -p "$OUT"
: > "$OUT/$RUN-events.txt"
note() { echo "$(date -u +%T) $*" | tee -a "$OUT/$RUN-events.txt"; }
metric() { grep -E "^ *$1[.:]" "$OUT/$RUN-k6.txt" | awk '{print $2}' | head -1 || true; }

# The READY PostgreSQL pod (during the failure the old one still exists, but isn't ready)
pg_pod() {
  kubectl get pods -n "$NS" -l app=postgres \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 == "True" {print $1; exit}'
}
# A query, or nothing within 5 s (PostgreSQL away)
sql() {
  local pod; pod=$(pg_pod)
  [ -n "$pod" ] || return 1
  timeout 5 kubectl exec -n "$NS" "$pod" -- psql -U postgres -tAc "$1" 2>/dev/null
}
queue() { timeout 5 kubectl exec -n "$NS" deploy/redis -- redis-cli LLEN votes 2>/dev/null; }

# 1. Where things run. Node name -> scale set + instance: aks-system-19447125-vmss000000
#    = scale set aks-system-19447125-vmss, instance 000000 (a base-36 number)
NODE=$(kubectl get pods -n "$NS" -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
VMSS="${NODE%??????}"
INSTANCE=$(( 36#${NODE: -6} ))
ZONE=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
note "run ${RUN}: PostgreSQL on ${NODE} (${ZONE}) = ${VMSS} instance ${INSTANCE}"
kubectl get pods -A -o wide --field-selector "spec.nodeName=${NODE}" | tee "$OUT/$RUN-on-failed-node.txt"
record_and_check_spread "$OUT/$RUN-spread.txt"
kubectl get pv -o custom-columns=PV:.metadata.name,CLAIM:.spec.claimRef.name > "$OUT/$RUN-pv.txt"

# 2. clean slate for this run's voter IDs
sql "DELETE FROM votes WHERE id LIKE 'k6f-${RUN}-%'" > /dev/null

# 3. k6 here: the local binary if there is one, otherwise the Docker image
if command -v k6 >/dev/null; then
  K6=(k6 run --out "csv=${OUT}/${RUN}-k6.csv" -)
else
  docker pull -q grafana/k6:0.54.0 >/dev/null
  K6=(docker run --rm -i -u "$(id -u):$(id -g)" -v "$PWD/$OUT:/results"
      -e RUN -e RATE -e DURATION -e TARGET -e BURST_AT grafana/k6:0.54.0 run --out "csv=/results/${RUN}-k6.csv" -)
fi
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT   # stopped early: stop k6 and the samplers too
note "k6 start: ${RATE} votes/s for ${DURATION} to ${TARGET}"
"${K6[@]}" < loadtest/vote-steady.js > "$OUT/$RUN-k6.txt" 2>&1 &
K6_PID=$!

# Samplers, every 2 s, until killed at the end
( echo "time_utc,node,ready"
  while true; do
    t=$(date -u +%T)
    kubectl get nodes --request-timeout=5s -o jsonpath='{range .items[*]}{.metadata.name},{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      | sed "s/^/${t},/" || true
    sleep 2
  done ) > "$OUT/$RUN-nodes.csv" &
( echo "time_utc,pod,node,phase,ready,deleting"
  while true; do
    t=$(date -u +%T)
    kubectl get pods -n "$NS" --request-timeout=5s -o jsonpath='{range .items[*]}{.metadata.name},{.spec.nodeName},{.status.phase},{.status.conditions[?(@.type=="Ready")].status},{.metadata.deletionTimestamp}{"\n"}{end}' \
      | sed "s/^/${t},/" || true
    sleep 2
  done ) > "$OUT/$RUN-pods.csv" &
( echo "time_utc,queue,saved"
  while true; do
    echo "$(date -u +%T),$(queue || echo down),$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'" || echo down)"
    sleep 2
  done ) > "$OUT/$RUN-data.csv" &
# Every Kubernetes event as it happens: NotReady, evictions, the disk's detach and attach
kubectl get events -A --watch-only \
  -o custom-columns=NS:.metadata.namespace,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message \
  2>/dev/null | while IFS= read -r line; do echo "$(date -u +%T) $line"; done > "$OUT/$RUN-k8s-events.txt" &

# 4. the failure
sleep "$FAIL_AFTER"
note "FAIL: az vmss deallocate ${VMSS} instance ${INSTANCE} (${NODE}, ${ZONE})"
az vmss deallocate -g "$NODE_RG" -n "$VMSS" --instance-ids "$INSTANCE" --no-wait
note "deallocate requested"

# Note the moments as they happen: node NotReady, PostgreSQL ready again elsewhere
until [ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != "True" ]; do sleep 2; done
note "node ${NODE} NotReady"
NEW_NODE="none"
for _ in $(seq 1 600); do   # at most 20 min
  P=$(pg_pod || true)
  if [ -n "$P" ] && [ "$(kubectl get pod -n "$NS" "$P" -o jsonpath='{.spec.nodeName}')" != "$NODE" ]; then
    NEW_NODE=$(kubectl get pod -n "$NS" "$P" -o jsonpath='{.spec.nodeName}')
    note "PostgreSQL ready again: ${P} on ${NEW_NODE} ($(kubectl get node "$NEW_NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'))"
    break
  fi
  sleep 2
done
[ "$NEW_NODE" = "none" ] && note "PostgreSQL NOT ready on another node after 20 min"

# 5. k6 ends; then wait until the Workers have emptied the queue (at most 10 min)
wait "$K6_PID" || true
note "k6 done"
for _ in $(seq 1 300); do
  [ "$(queue || echo x)" = "0" ] && break
  sleep 2
done
sleep 10   # the last votes in the Workers' hands
note "queue empty"
kill $(jobs -p) 2>/dev/null || true

# 6. the numbers
SAVED=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'" || echo 0)   # 0 = PostgreSQL not reachable
SENT=$(metric http_reqs);              SENT=${SENT:-0}
ACCEPTED=$(metric votes_accepted);     ACCEPTED=${ACCEPTED:-0}
BY_VOTE=$(metric refused_by_vote);     BY_VOTE=${BY_VOTE:-0}
BY_GW=$(metric refused_by_gateway);    BY_GW=${BY_GW:-0}
NO_ANSWER=$(metric refused_no_answer); NO_ANSWER=${NO_ANSWER:-0}
MAXQ=$(awk -F, 'NR > 1 && $2 ~ /^[0-9]+$/ && $2 > m {m = $2} END {print m + 0}' "$OUT/$RUN-data.csv")
{
  echo
  echo "=== Run ${RUN}: ${NODE} (${ZONE}) switched off, PostgreSQL moved to ${NEW_NODE}"
  cat "$OUT/$RUN-events.txt"
  echo
  echo "sent ${SENT} | accepted (200) ${ACCEPTED} | refused: by Vote ${BY_VOTE}, by Gateway ${BY_GW}, no answer ${NO_ANSWER}"
  echo "saved ${SAVED} | saved minus accepted $(( SAVED - ACCEPTED ))  (negative = accepted votes lost)"
  echo "largest Redis queue ${MAXQ}"
  echo "first and last refused vote:"
  grep -o '[0-9T:.-]*Z refused.*' "$OUT/$RUN-k6.txt" | sed -n '1p;$p' || true
  echo
  echo "pods now:"
  kubectl get pods -n "$NS" -o wide
  echo
  echo "events about the disk and PostgreSQL:"
  grep -E "postgres|pvc-|Attach|Evict|NodeNotReady|Taint" "$OUT/$RUN-k8s-events.txt" || true
} | tee "$OUT/$RUN-summary.txt"

# 7. the node back
note "az vmss start ${VMSS} instance ${INSTANCE}"
az vmss start -g "$NODE_RG" -n "$VMSS" --instance-ids "$INSTANCE"
kubectl wait node "$NODE" --for=condition=Ready --timeout=10m && note "node ${NODE} Ready again"
kubectl get pods -n "$NS" -o wide
