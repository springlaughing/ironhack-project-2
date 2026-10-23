#!/usr/bin/env bash
# Is the voting app really working? Checks the pages through the Gateway,
# then sends one vote and waits until the Worker has saved it in PostgreSQL.
#   ./smoke-test.sh              check pages and one vote
#   ./smoke-test.sh --no-vote    pages only (adds nothing to the database)
# Exit code 0 = everything works, 1 = something failed. Used at the end of
# setup-cluster.sh, later as the pipeline's last step.
set -uo pipefail                 # no -e: we count failures ourselves

NAMESPACE="voting-app"
VOTE_CHECK=true
[ "${1:-}" = "--no-vote" ] && VOTE_CHECK=false
FAILED=0

GW=$(kubectl get gateway voting-gateway -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[ -z "$GW" ] && { echo "FAIL  no Gateway address (is the Gateway there?)"; exit 1; }
BASE="http://${GW}"
echo "Gateway: ${BASE}"

# A brand-new NLB needs a few minutes before its DNS name works: wait up to 5 minutes.
for i in $(seq 1 30); do
  curl -s -m 5 -o /dev/null "${BASE}/vote" && break
  [ "$i" -eq 1 ] && echo "waiting for the NLB to answer (new NLBs take a few minutes) ..."
  sleep 10
done

check() {  # check <path> <expected status code>
  local code
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${BASE}$1")
  if [ "$code" = "$2" ]; then echo "ok    $code  $1"; else echo "FAIL  $code  $1 (expected $2)"; FAILED=1; fi
}

check /vote        200       # Vote's page
check /            200       # also Vote (the form posts here)
check /result      301       # Result redirects to /result/ itself
check /result/     200       # Result's page
check /result/app.js 200     # one of Result's files

if $VOTE_CHECK; then
  # One vote from a fixed test voter. The Worker saves votes with an upsert per voter,
  # so repeated smoke tests always update this same row instead of adding new ones.
  VOTER="smoke-test"
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -b "voter_id=${VOTER}" -d "vote=a" "${BASE}/")
  if [ "$code" = "200" ]; then echo "ok    $code  POST / (vote for a as ${VOTER})"; else echo "FAIL  $code  POST /"; FAILED=1; fi

  # Vote -> Redis -> Worker -> PostgreSQL: wait up to 20 s for the row.
  saved=""
  for _ in $(seq 1 20); do
    saved=$(kubectl exec -n "$NAMESPACE" deploy/postgres -- \
      psql -U postgres -tAc "SELECT vote FROM votes WHERE id = '${VOTER}'" 2>/dev/null)
    [ "$saved" = "a" ] && break
    sleep 1
  done
  if [ "$saved" = "a" ]; then echo "ok    vote saved in PostgreSQL"; else echo "FAIL  vote not in PostgreSQL after 20 s"; FAILED=1; fi
fi

if [ "$FAILED" -eq 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit "$FAILED"
