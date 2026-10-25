#!/usr/bin/env bash
# #9 rollout runs: a steady stream of votes, and 60 s in, a rolling update of one workload,
# at the same moment as a spike of 400 votes/s for 5 s (the host says "vote now").
#   ./loadtest/rollout-test.sh A deployment/vote      Run A: Vote without readiness probe and preStop
#   ./loadtest/rollout-test.sh B deployment/vote      Run B: Vote with both (k8s/app/vote.yaml)
#   ./loadtest/rollout-test.sh D statefulset/worker   Run D: the Worker
# The update is "kubectl rollout restart": every pod is replaced by a new one, exactly like
# a new image, but with the same image, so the only difference between runs is the setup.
# k6 runs in AWS CloudShell, close to the app (K6_WHERE=cloudshell, the default): this script
# prints the k6 command and notices k6's start by the first saved vote. K6_WHERE=local runs
# k6 here instead (binary or Docker), as for run A from Germany.
# Steps:
#   1. delete this run's votes from an earlier try (k6f-<RUN>-...)
#   2. start k6 (or print its command for CloudShell and wait for the first saved vote)
#   3. start three samplers, once a second: Redis queue and saved votes (inside the pods),
#      and the workload's pods (version, ready, shutting down)
#   4. 60 s after k6's start: rollout restart, wait until done; both times noted
#   5. wait for the samplers (they run 90 s longer than k6, so the Worker can catch up)
#   6. print: saved in PostgreSQL (and with local k6: accepted, refused by whom, lost)
#   7. local k6 only: draw the timeline with loadtest/plot.py
# Everything lands in loadtest/results/<RUN>-*.
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="${1:?usage: rollout-test.sh <run letter> <workload, e.g. deployment/vote>}"
WORKLOAD="${2:?usage: rollout-test.sh <run letter> <workload, e.g. deployment/vote>}"
NS="voting-app"
K6_WHERE="${K6_WHERE:-cloudshell}"  # cloudshell | local
K6_SECONDS="${K6_SECONDS:-180}"     # how long k6 sends votes
UPDATE_AFTER="${UPDATE_AFTER:-60}"  # when the update starts, seconds after k6
SAMPLE_SECONDS=$(( K6_SECONDS + 90 ))
APP="${WORKLOAD#*/}"                # deployment/vote -> vote (the pods' app label)
export RUN RATE="${RATE:-50}" DURATION="${K6_SECONDS}s" TARGET="${TARGET:-https://k8s.springlaughing.dev/}"
export BURST_AT="${BURST_AT-${UPDATE_AFTER}s}"   # the spike starts with the update; BURST_AT= for none

OUT="loadtest/results"
mkdir -p "$OUT"
: > "$OUT/$RUN-events.txt"
note() { echo "$(date -u +%T) $*" | tee -a "$OUT/$RUN-events.txt"; }
metric() { grep -E "^ *$1[.:]" "$OUT/$RUN-k6.txt" | awk '{print $2}' | head -1 || true; }   # a k6 summary number
sql() { kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -tAc "$1"; }
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT   # stopped early: stop k6 and the samplers too

# Once a second, one line per pod: time, name, version (template hash), ready, shutting down.
# Deployment pods carry pod-template-hash, StatefulSet pods controller-revision-hash.
sample_pods() {
  local end=$(( $(date +%s) + SAMPLE_SECONDS )) t
  echo "time_utc,pod,version,ready,terminating"
  while [ "$(date +%s)" -lt "$end" ]; do
    t=$(date -u +%T)
    kubectl get pods -n "$NS" -l "app=${APP}" -o jsonpath='{range .items[*]}{.metadata.name},{.metadata.labels.pod-template-hash}{.metadata.labels.controller-revision-hash},{.status.containerStatuses[0].ready},{.metadata.deletionTimestamp}{"\n"}{end}' \
      | sed "s/^/${t},/"
    sleep 1
  done
}

note "run ${RUN}: ${WORKLOAD} ($(kubectl get "$WORKLOAD" -n "$NS" -o jsonpath='{.spec.replicas} replicas, {.spec.template.spec.containers[0].image}'))"
sql "DELETE FROM votes WHERE id LIKE 'k6f-${RUN}-%'" > /dev/null

if [ "$K6_WHERE" = "cloudshell" ]; then
  echo
  echo "Now in CloudShell (k6 writes every vote to ~/${RUN}-k6.csv, then packs both files):"
  echo "  cd ~/ironhack-project-2 && git pull -q && k6 run --out csv=\$HOME/${RUN}-k6.csv -e RUN=${RUN} -e RATE=${RATE} -e DURATION=${DURATION} -e TARGET=${TARGET} -e BURST_AT=${BURST_AT} loadtest/vote-steady.js 2>&1 | tee ~/${RUN}-k6.txt; tar czf ~/${RUN}-k6.tgz -C ~ ${RUN}-k6.txt ${RUN}-k6.csv"
  echo
  echo "Waiting for the first vote of run ${RUN} ..."
  until [ "$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")" -gt 0 ]; do sleep 0.5; done
  note "k6 start: first vote saved (${RATE} votes/s for ${DURATION}, burst at ${BURST_AT:-none})"
else
  # k6 here: the local binary if there is one, otherwise the Docker image (as in Project 1)
  if command -v k6 >/dev/null; then
    K6=(k6 run --out "csv=${OUT}/${RUN}-k6.csv" -)
  else
    # -u: run as me, so k6 may write its CSV into my folder (mounted as /results)
    docker pull -q grafana/k6:0.54.0 >/dev/null
    K6=(docker run --rm -i -u "$(id -u):$(id -g)" -v "$PWD/$OUT:/results"
        -e RUN -e RATE -e DURATION -e TARGET -e BURST_AT grafana/k6:0.54.0 run --out "csv=/results/${RUN}-k6.csv" -)
  fi
  note "k6 start: ${RATE} votes/s for ${DURATION} to ${TARGET}, burst at ${BURST_AT:-none}"
  "${K6[@]}" < loadtest/vote-steady.js > "$OUT/$RUN-k6.txt" 2>&1 &
  K6_PID=$!
fi

# the samplers, from k6's start on
kubectl exec -i -n "$NS" deploy/redis -- sh -s "$SAMPLE_SECONDS" \
  < loadtest/sample-queue.sh > "$OUT/$RUN-queue.csv" &
QUEUE_PID=$!
kubectl exec -i -n "$NS" deploy/postgres -- sh -s "$RUN" "$SAMPLE_SECONDS" \
  < loadtest/sample-db.sh > "$OUT/$RUN-saved.csv" &
SAVED_PID=$!
sample_pods > "$OUT/$RUN-pods.csv" &
PODS_PID=$!

sleep "$UPDATE_AFTER"
note "update start: kubectl rollout restart ${WORKLOAD}"
kubectl rollout restart "$WORKLOAD" -n "$NS"
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=5m
note "update done"
kubectl get pods -n "$NS" -l "app=${APP}" -o wide

if [ "$K6_WHERE" != "cloudshell" ]; then
  wait "$K6_PID" || true
  note "k6 done"
fi
echo "waiting for the samplers (the Worker saves the last votes meanwhile) ..."
wait "$QUEUE_PID" "$SAVED_PID" "$PODS_PID" || true
note "samplers done"

SAVED=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")
SAVED_BURST=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-b-%'")
MAXQ=$(awk -F, 'NR > 1 && $2 + $3 > m {m = $2 + $3} END {print m + 0}' "$OUT/$RUN-queue.csv")
{
  echo
  echo "=== Run ${RUN} (${WORKLOAD})"
  echo "saved in PostgreSQL ${SAVED} (burst ${SAVED_BURST}) | largest Redis queue ${MAXQ}"
  if [ "$K6_WHERE" = "cloudshell" ]; then
    echo "k6's numbers (sent, accepted, refused by whom): in CloudShell, ~/${RUN}-k6.tgz"
  else
    SENT=$(metric http_reqs);              SENT=${SENT:-0}
    ACCEPTED=$(metric votes_accepted);     ACCEPTED=${ACCEPTED:-0}
    BY_VOTE=$(metric refused_by_vote);     BY_VOTE=${BY_VOTE:-0}
    BY_GW=$(metric refused_by_gateway);    BY_GW=${BY_GW:-0}
    NO_ANSWER=$(metric refused_no_answer); NO_ANSWER=${NO_ANSWER:-0}
    DROPPED=$(metric dropped_iterations);  DROPPED=${DROPPED:-0}
    echo "sent ${SENT} | accepted (200) ${ACCEPTED} | refused: by Vote ${BY_VOTE}, by Gateway ${BY_GW}, no answer ${NO_ANSWER} | not sent by k6 ${DROPPED}"
    echo "saved minus accepted $(( SAVED - ACCEPTED ))  (negative = accepted votes lost)"
    echo "first and last refused vote:"
    grep -o '[0-9T:.-]*Z refused.*' "$OUT/$RUN-k6.txt" | sed -n '1p;$p' || true
    grep -E "http_req_duration|iteration_duration" "$OUT/$RUN-k6.txt" || true
  fi
} | tee "$OUT/$RUN-summary.txt"

# the timeline picture needs k6's per-vote CSV: here only when k6 ran here
if [ "$K6_WHERE" != "cloudshell" ]; then
  python3 loadtest/plot.py "$RUN" || echo "  no picture: python3 -c 'import matplotlib' fails? sudo apt install -y python3-matplotlib"
fi
