#!/usr/bin/env bash
# #9 run BG: blue-green instead of a rolling update, under the same load as runs A, B and C2.
#   ./loadtest/bluegreen-test.sh            (run name BG)
# Blue  = the Deployment "vote" as it runs now (k8s/app/vote.yaml), pods labelled app=vote.
# Green = a second Deployment "vote-green", made from vote.yaml with only the names changed
#         (same image as blue, same probe, preStop, resources), pods labelled app=vote-green.
# The Service "vote" (and so NGINX) sends votes to whichever colour its selector names.
# The switch is one command: change the selector from app=vote to app=vote-green.
# Steps:
#   1. start green next to blue (12 Vote pods) and wait until all green pods are Ready
#   2. delete this run's votes from an earlier try (k6f-BG-...)
#   3. print the k6 command for CloudShell, wait for the first saved vote
#   4. start the samplers: Redis queue, saved votes, Vote pods of both colours
#   5. 60 s after k6's start, together with the spike: switch the Service to green
#   6. wait for the samplers, print the summary
#   7. clean up: switch back to blue (the rollback: one command too), delete green,
#      so the cluster is again exactly what Git describes
# If the script is stopped early, it switches the Service back to blue (blue is still running).
# Everything lands in loadtest/results/BG-*.
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="${1:-BG}"
NS="voting-app"
K6_SECONDS="${K6_SECONDS:-180}"
SWITCH_AFTER="${SWITCH_AFTER:-60}"
SAMPLE_SECONDS=$(( K6_SECONDS + 90 ))
RATE="${RATE:-50}" DURATION="${K6_SECONDS}s" TARGET="${TARGET:-https://k8s.springlaughing.dev/}"
BURST_AT="${BURST_AT-${SWITCH_AFTER}s}"

OUT="loadtest/results"
mkdir -p "$OUT"
: > "$OUT/$RUN-events.txt"
note() { echo "$(date -u +%T) $*" | tee -a "$OUT/$RUN-events.txt"; }
sql() { kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -tAc "$1"; }
selector() { kubectl get svc vote -n "$NS" -o jsonpath='{.spec.selector.app}'; }
switch_to() { kubectl patch svc vote -n "$NS" -p "{\"spec\":{\"selector\":{\"app\":\"$1\"}}}"; }

# stopped early: stop the samplers, and send votes to blue again
cleanup() {
  kill $(jobs -p) 2>/dev/null || true
  if [ "$(selector)" != "vote" ]; then
    switch_to vote && echo "stopped early: Service switched back to blue; delete green with:"
    echo "  kubectl delete deploy vote-green -n $NS"
  fi
}
trap cleanup EXIT

# Once a second, one line per Vote pod of either colour: time, pod, colour, ready, shutting down.
sample_pods() {
  local end=$(( $(date +%s) + SAMPLE_SECONDS )) t
  echo "time_utc,pod,colour,ready,terminating"
  while [ "$(date +%s)" -lt "$end" ]; do
    t=$(date -u +%T)
    kubectl get pods -n "$NS" -l 'app in (vote,vote-green)' -o jsonpath='{range .items[*]}{.metadata.name},{.metadata.labels.app},{.status.containerStatuses[0].ready},{.metadata.deletionTimestamp}{"\n"}{end}' \
      | sed "s/^/${t},/"
    sleep 1
  done
}

# 1. green next to blue
[ "$(selector)" = "vote" ] || { echo "The Service doesn't point at blue (app=vote). Stop."; exit 1; }
IMG=$(kubectl get deploy vote -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
note "run ${RUN}: blue = deployment/vote ($(kubectl get deploy vote -n "$NS" -o jsonpath='{.spec.replicas}') replicas, ${IMG})"
# vote.yaml up to the "---" (the Deployment only, not the Service), renamed, with blue's image
awk '/^---/{exit} {print}' k8s/app/vote.yaml \
  | sed -e 's/^  name: vote$/  name: vote-green/' \
        -e 's/app: vote$/app: vote-green/' \
        -e "s|image: springlaughing/voting-vote:[^ ]*|image: ${IMG}|" \
  | kubectl apply -n "$NS" -f -
kubectl rollout status deploy/vote-green -n "$NS" --timeout=3m
note "green ready: $(kubectl get deploy vote-green -n "$NS" -o jsonpath='{.status.readyReplicas}') pods"
kubectl get pods -n "$NS" -l 'app in (vote,vote-green)' -o wide --sort-by=.spec.nodeName

# 2. + 3. clean slate, then k6 in CloudShell
sql "DELETE FROM votes WHERE id LIKE 'k6f-${RUN}-%'" > /dev/null
echo
echo "Now in CloudShell (k6 writes every vote to ~/${RUN}-k6.csv, then packs both files):"
echo "  cd ~/ironhack-project-2 && git pull -q && k6 run --out csv=\$HOME/${RUN}-k6.csv -e RUN=${RUN} -e RATE=${RATE} -e DURATION=${DURATION} -e TARGET=${TARGET} -e BURST_AT=${BURST_AT} loadtest/vote-steady.js 2>&1 | tee ~/${RUN}-k6.txt; tar czf ~/${RUN}-k6.tgz -C ~ ${RUN}-k6.txt ${RUN}-k6.csv"
echo
echo "Waiting for the first vote of run ${RUN} ..."
until [ "$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")" -gt 0 ]; do sleep 0.5; done
note "k6 start: first vote saved (${RATE} votes/s for ${DURATION}, burst at ${BURST_AT:-none})"

# 4. samplers
kubectl exec -i -n "$NS" deploy/redis -- sh -s "$SAMPLE_SECONDS" \
  < loadtest/sample-queue.sh > "$OUT/$RUN-queue.csv" &
QUEUE_PID=$!
kubectl exec -i -n "$NS" deploy/postgres -- sh -s "$RUN" "$SAMPLE_SECONDS" \
  < loadtest/sample-db.sh > "$OUT/$RUN-saved.csv" &
SAVED_PID=$!
sample_pods > "$OUT/$RUN-pods.csv" &
PODS_PID=$!

# 5. the switch
sleep "$SWITCH_AFTER"
note "switch start: Service vote -> app=vote-green"
switch_to vote-green
note "switch done: selector is now app=$(selector)"
kubectl get endpointslices -n "$NS" -l kubernetes.io/service-name=vote \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} {.targetRef.name} ready={.conditions.ready}{"\n"}{end}'

# 6. wait, then the summary
echo "waiting for the samplers (the Worker saves the last votes meanwhile) ..."
wait "$QUEUE_PID" "$SAVED_PID" "$PODS_PID" || true
note "samplers done"
SAVED=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")
SAVED_BURST=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-b-%'")
MAXQ=$(awk -F, 'NR > 1 && $2 + $3 > m {m = $2 + $3} END {print m + 0}' "$OUT/$RUN-queue.csv")
{
  echo
  echo "=== Run ${RUN} (blue-green, switch at ${SWITCH_AFTER} s)"
  echo "saved in PostgreSQL ${SAVED} (burst ${SAVED_BURST}) | largest Redis queue ${MAXQ}"
  echo "k6's numbers (sent, accepted, refused by whom): in CloudShell, ~/${RUN}-k6.tgz"
} | tee "$OUT/$RUN-summary.txt"

# 7. rollback to blue and remove green: back to what Git describes
note "rollback: Service vote -> app=vote"
switch_to vote
note "rollback done: selector is now app=$(selector)"
sleep 15   # NGINX has moved to blue; then green's pods get their usual graceful stop
kubectl delete deploy vote-green -n "$NS"
note "green deleted"
kubectl get pods -n "$NS" -l 'app in (vote,vote-green)'
