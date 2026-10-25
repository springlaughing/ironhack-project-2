#!/usr/bin/env bash
# #9 rollout runs: a steady stream of votes, and 60 s in, a rolling update of one workload.
#   ./loadtest/rollout-test.sh A deployment/vote      Run A: Vote without readiness probe and preStop
#   ./loadtest/rollout-test.sh B deployment/vote      Run B: Vote with both (k8s/app/vote.yaml)
#   ./loadtest/rollout-test.sh D statefulset/worker   Run D: the Worker
# The update is "kubectl rollout restart": every pod is replaced by a new one, exactly like
# a new image, but with the same image, so the only difference between runs is the setup.
# Steps:
#   1. delete this run's votes from an earlier try (k6f-<RUN>-...)
#   2. start two samplers inside the pods, once a second: Redis queue, saved votes
#   3. start k6: 50 votes/s for 3 minutes (loadtest/vote-steady.js)
#   4. 60 s later: rollout restart, wait until done; both times noted
#   5. wait for k6, then for the samplers (they run 90 s longer, so the Worker can catch up)
#   6. print: accepted, refused (by whom), saved in PostgreSQL, lost
# Everything lands in loadtest/results/<RUN>-*.
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="${1:?usage: rollout-test.sh <run letter> <workload, e.g. deployment/vote>}"
WORKLOAD="${2:?usage: rollout-test.sh <run letter> <workload, e.g. deployment/vote>}"
NS="voting-app"
K6_SECONDS="${K6_SECONDS:-180}"     # how long k6 sends votes
UPDATE_AFTER="${UPDATE_AFTER:-60}"  # when the update starts, seconds after k6
SAMPLE_SECONDS=$(( K6_SECONDS + 90 ))
export RUN RATE="${RATE:-50}" DURATION="${K6_SECONDS}s" TARGET="${TARGET:-https://k8s.springlaughing.dev/}"

OUT="loadtest/results"
mkdir -p "$OUT"
: > "$OUT/$RUN-events.txt"
note() { echo "$(date -u +%T) $*" | tee -a "$OUT/$RUN-events.txt"; }
metric() { grep -E "^ *$1[.:]" "$OUT/$RUN-k6.txt" | awk '{print $2}' | head -1 || true; }   # a k6 summary number
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT   # stopped early: stop k6 and the samplers too

# k6: the local binary if there is one, otherwise the Docker image (as in Project 1)
if command -v k6 >/dev/null; then
  K6=(k6 run -)
else
  docker pull -q grafana/k6:0.54.0 >/dev/null
  K6=(docker run --rm -i -e RUN -e RATE -e DURATION -e TARGET grafana/k6:0.54.0 run -)
fi

note "run ${RUN}: ${WORKLOAD} ($(kubectl get "$WORKLOAD" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}'))"
note "clocks: here $(date -u +%T), cluster $(kubectl exec -n "$NS" deploy/redis -- date -u +%T)"
kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -qc "DELETE FROM votes WHERE id LIKE 'k6f-${RUN}-%'"

kubectl exec -i -n "$NS" deploy/redis -- sh -s "$SAMPLE_SECONDS" \
  < loadtest/sample-queue.sh > "$OUT/$RUN-queue.csv" &
QUEUE_PID=$!
kubectl exec -i -n "$NS" deploy/postgres -- sh -s "$RUN" "$SAMPLE_SECONDS" \
  < loadtest/sample-db.sh > "$OUT/$RUN-saved.csv" &
SAVED_PID=$!

note "k6 start: ${RATE} votes/s for ${DURATION} to ${TARGET}"
"${K6[@]}" < loadtest/vote-steady.js > "$OUT/$RUN-k6.txt" 2>&1 &
K6_PID=$!

sleep "$UPDATE_AFTER"
note "update start: kubectl rollout restart ${WORKLOAD}"
kubectl rollout restart "$WORKLOAD" -n "$NS"
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=5m
note "update done"
kubectl get pods -n "$NS" -l "app=${WORKLOAD#*/}" -o wide

wait "$K6_PID" || true
note "k6 done"
echo "waiting for the samplers (the Worker saves the last votes meanwhile) ..."
wait "$QUEUE_PID" "$SAVED_PID" || true
note "samplers done"

SENT=$(metric http_reqs);              SENT=${SENT:-0}
ACCEPTED=$(metric votes_accepted);     ACCEPTED=${ACCEPTED:-0}
BY_VOTE=$(metric refused_by_vote);     BY_VOTE=${BY_VOTE:-0}
BY_GW=$(metric refused_by_gateway);    BY_GW=${BY_GW:-0}
NO_ANSWER=$(metric refused_no_answer); NO_ANSWER=${NO_ANSWER:-0}
DROPPED=$(metric dropped_iterations);  DROPPED=${DROPPED:-0}
SAVED=$(kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -tAc \
  "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")

{
  echo
  echo "=== Run ${RUN} (${WORKLOAD})"
  echo "sent ${SENT} | accepted (200) ${ACCEPTED} | refused: by Vote ${BY_VOTE}, by Gateway ${BY_GW}, no answer ${NO_ANSWER} | not sent by k6 ${DROPPED}"
  echo "saved in PostgreSQL ${SAVED} | saved minus accepted $(( SAVED - ACCEPTED ))  (negative = accepted votes lost)"
  echo "first and last refused vote:"
  grep -o '[0-9T:.-]*Z refused.*' "$OUT/$RUN-k6.txt" | sed -n '1p;$p' || true
  grep -E "http_req_duration|iteration_duration" "$OUT/$RUN-k6.txt" || true
} | tee "$OUT/$RUN-summary.txt"
