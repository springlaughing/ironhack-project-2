#!/usr/bin/env bash
# Spike test (#9): Project 1's load test 2 against the EKS app. 60 s of normal traffic
# (50 votes/s), then the brief's spike: 2,000 votes in 5 s (400/s).
# k6 runs in AWS CloudShell, close to the app (as Project 1's run-aws.sh with K6_WHERE=cloudshell).
# This script runs on the PC and does everything else:
#   1. shows what Vote runs (replicas, image, readiness probe)
#   2. deletes old spike votes (k6-... = burst, k6w-... = warm-up)
#   3. prints the k6 command for CloudShell and waits for the first warm-up vote
#   4. then, for 150 s: Redis queue and saved votes once a second (inside the pods), and
#      CPU/memory of the app and NGINX pods every 2 s (kubectl top, if metrics-server exists)
#   5. prints the result: saved votes, largest queue, time to save the burst, highest CPU
# Usage: ./loadtest/spike-test.sh [name]    results in loadtest/results/spike-<name>-*
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-2pods}"
NS="voting-app"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-150}"   # warm-up 60 s + burst 5 s + time for the Worker
TARGET="${TARGET:-https://k8s.springlaughing.dev/}"
OUT="loadtest/results"
mkdir -p "$OUT"
P="$OUT/spike-$NAME"

sql() { kubectl exec -n "$NS" deploy/postgres -- psql -U postgres -tAc "$1"; }

# 1. what is being tested
echo "Vote: $(kubectl get deploy vote -n "$NS" -o jsonpath='{.spec.replicas} replicas, image {.spec.template.spec.containers[0].image}, readiness probe on "{.spec.template.spec.containers[0].readinessProbe.httpGet.path}"')" | tee "$P-setup.txt"
kubectl get pods -n "$NS" -l app=vote -o wide | tee -a "$P-setup.txt"

# 2. a clean start
sql "DELETE FROM votes WHERE id LIKE 'k6-%' OR id LIKE 'k6w-%'" > /dev/null
echo "Old spike votes deleted."

# 3. k6 starts in CloudShell; we notice it by the first saved warm-up vote
echo
echo "Now in CloudShell:"
echo "  cd ~/ironhack-project-2 && k6 run -e TARGET=$TARGET -e WARMUP=60s -e WARMUP_RATE=50 -e PRE_VUS=800 -e MAX_VUS=1200 loadtest/vote-burst.js 2>&1 | tee ~/spike-$NAME-k6.txt"
echo
echo "Waiting for the first warm-up vote ..."
until [ "$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6w-%'")" -gt 0 ]; do sleep 1; done
echo "$(date -u +%T) k6 is running. Measuring for ${SAMPLE_SECONDS} s ..."

# 4. measure
kubectl exec -i -n "$NS" deploy/redis -- sh -s "$SAMPLE_SECONDS" \
  < loadtest/sample-queue.sh > "$P-queue.csv" &
# inside PostgreSQL: saved burst and warm-up votes, once a second (psql -A prints "12|345")
kubectl exec -i -n "$NS" deploy/postgres -- sh -s "$SAMPLE_SECONDS" > "$P-saved.csv" <<'EOF' &
end=$(( $(date +%s) + $1 ))
echo "time_utc,burst,warmup"
while [ "$(date +%s)" -lt "$end" ]; do
  echo "$(date -u +%T),$(psql -U postgres -tAc "SELECT COUNT(*) FILTER (WHERE id LIKE 'k6-%'), COUNT(*) FILTER (WHERE id LIKE 'k6w-%') FROM votes" | tr '|' ',')"
  sleep 1
done
EOF
if kubectl top pods -n "$NS" > /dev/null 2>&1; then
  (
    end=$(( $(date +%s) + SAMPLE_SECONDS ))
    echo "time_utc,namespace,pod,cpu,memory"
    while [ "$(date +%s)" -lt "$end" ]; do
      t=$(date -u +%T)
      kubectl top pods -A --no-headers | awk -v t="$t" '$1 == "voting-app" || $1 == "nginx-gateway" {print t "," $1 "," $2 "," $3 "," $4}'
      sleep 2
    done
  ) > "$P-top.csv" &
else
  echo "(no metrics-server: no CPU measurement)"
fi
wait

# 5. the result
BURST=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6-%'")
WARM=$(sql "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6w-%'")
# seconds from the first saved burst vote until all burst votes were saved
SAVE_TIME=$(awk -F, -v n="$BURST" 'NR > 1 && $2 > 0 && !s {split($1, a, ":"); s = a[1]*3600 + a[2]*60 + a[3]}
  NR > 1 && $2 == n && n > 0 && !e {split($1, a, ":"); e = a[1]*3600 + a[2]*60 + a[3]}
  END {if (s && e) print e - s; else print "?"}' "$P-saved.csv")
MAXQ=$(awk -F, 'NR > 1 && $2 + $3 > m {m = $2 + $3} END {print m + 0}' "$P-queue.csv")
{
  echo
  echo "=== Spike ${NAME}"
  echo "saved in PostgreSQL: burst ${BURST} (k6 sends 2000), warm-up ${WARM} (k6 sends 3000)"
  echo "largest Redis queue (waiting + in progress): ${MAXQ} votes"
  echo "first to last burst vote saved: ${SAVE_TIME} s"
  if [ -s "$P-top.csv" ]; then
    echo "highest CPU per pod (kubectl top, 500m = Vote's limit):"
    awk -F, 'NR > 1 {v = $4; sub("m", "", v); if (v + 0 > max[$3]) max[$3] = v + 0}
      END {for (p in max) printf "  %-45s %sm\n", p, max[p]}' "$P-top.csv" | sort
  fi
  echo "k6's own numbers: in CloudShell, ~/spike-${NAME}-k6.txt"
} | tee "$P-summary.txt"
