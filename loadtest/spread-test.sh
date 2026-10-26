#!/usr/bin/env bash
# #9 spread runs: the same load as the rollout runs (50 votes/s, plus 400/s for 5 s at 60 s),
# but NO update. The question: does it matter how the Vote pods sit on the nodes?
#   ./loadtest/spread-test.sh E1                     even spread (2 + 2 + 2); refuses otherwise
#   ALLOW_UNEVEN=1 ./loadtest/spread-test.sh U1      after ./loadtest/make-uneven.sh <node>
# Besides the queue and the saved votes, it samples each node's CPU once a second, from /proc/stat
# inside one Vote pod per node (/proc/stat counts the whole node, not just that pod).
# Afterwards: the NGINX reloads during the run (should be 0: nothing changes) and, per node,
# the most CPU used in one second. Everything lands in loadtest/results/<RUN>-*.
set -euo pipefail
cd "$(dirname "$0")/.."
source loadtest/lib-cluster.sh

RUN="${1:?usage: spread-test.sh <run name, e.g. E1 or U1>}"
NS="voting-app"
K6_SECONDS="${K6_SECONDS:-180}"
SAMPLE_SECONDS=$(( K6_SECONDS + 60 ))
RATE="${RATE:-50}" DURATION="${K6_SECONDS}s" TARGET="${TARGET:-https://k8s.springlaughing.dev/}"
BURST_AT="${BURST_AT-60s}"

OUT="loadtest/results"
mkdir -p "$OUT"
: > "$OUT/$RUN-events.txt"
note() { echo "$(date -u +%T) $*" | tee -a "$OUT/$RUN-events.txt"; }
sql() { kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -tAc "$1"; }
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

# 1. where everything runs, and is the spread what this run expects?
note "run ${RUN}: no update, $(kubectl get deploy vote -n "$NS" -o jsonpath='{.spec.replicas} Vote replicas, {.spec.template.spec.containers[0].image}')"
record_and_check_spread "$OUT/$RUN-spread.txt"

# 2. clean slate, k6 in CloudShell
sql "DELETE FROM votes WHERE id LIKE 'k6f-${RUN}-%'" > /dev/null
echo
echo "Now in CloudShell (k6 writes every vote to ~/${RUN}-k6.csv, then packs both files):"
echo "  cd ~/ironhack-project-2 && git pull -q && k6 run --out csv=\$HOME/${RUN}-k6.csv -e RUN=${RUN} -e RATE=${RATE} -e DURATION=${DURATION} -e TARGET=${TARGET} -e BURST_AT=${BURST_AT} loadtest/vote-steady.js 2>&1 | tee ~/${RUN}-k6.txt; tar czf ~/${RUN}-k6.tgz -C ~ ${RUN}-k6.txt ${RUN}-k6.csv"
echo
echo "Waiting for the first vote of run ${RUN} ..."
until [ "$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")" -gt 0 ]; do sleep 0.5; done
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
note "k6 start: first vote saved (${RATE} votes/s for ${DURATION}, burst at ${BURST_AT:-none})"

# 3. samplers: queue, saved votes, and the CPU of every node (through one Vote pod on it)
kubectl exec -i -n "$NS" deploy/redis -- sh -s "$SAMPLE_SECONDS" \
  < loadtest/sample-queue.sh > "$OUT/$RUN-queue.csv" &
kubectl exec -i -n "$NS" deploy/postgres -- sh -s "$RUN" "$SAMPLE_SECONDS" \
  < loadtest/sample-db.sh > "$OUT/$RUN-saved.csv" &
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  pod=$(kubectl get pods -n "$NS" -l app=vote --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -i -n "$NS" "$pod" -- sh -s "$SAMPLE_SECONDS" \
    < loadtest/sample-node-cpu.sh > "$OUT/$RUN-cpu-${node%%.*}.csv" &
done
echo "sampling for ${SAMPLE_SECONDS} s ..."
wait
note "samplers done"

# 4. the summary
SAVED=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-%'")
SAVED_BURST=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${RUN}-b-%'")
MAXQ=$(awk -F, 'NR > 1 && $2 + $3 > m {m = $2 + $3} END {print m + 0}' "$OUT/$RUN-queue.csv")
RELOADS=$(count_reloads "$START" "$OUT/$RUN-reloads.txt")
{
  echo
  echo "=== Run ${RUN} (no update)"
  echo "saved in PostgreSQL ${SAVED} (burst ${SAVED_BURST}) | largest Redis queue ${MAXQ} | NGINX reloads ${RELOADS}"
  echo "Vote pods per node, and the most CPU the node used in one second (of its CPUs; steal = CPU the hypervisor held back):"
  for f in "$OUT/$RUN"-cpu-*.csv; do
    node=${f##*-cpu-}; node=${node%.csv}
    pods=$(vote_spread | awk -v n="$node" 'index($1, n) == 1 {print $2}')
    awk -F, -v node="$node" -v pods="$pods" '
      NR > 2 && $4 > t {used = ($2 - b) / ($4 - t) * $5; st = ($3 - s) / ($4 - t) * $5
                        if (used > max) {max = used; at = $1; stmax = st}}
      NR > 1 {b = $2; s = $3; t = $4; ncpu = $5}
      END {printf "  %-15s %s Vote pods   max %.2f of %d CPUs at %s (steal %.2f)\n", node, pods, max, ncpu, at, stmax}' "$f"
  done
  echo "k6's numbers (sent, accepted, refused, answer times): in CloudShell, ~/${RUN}-k6.tgz"
} | tee "$OUT/$RUN-summary.txt"
