# Shared helpers for the #9 test scripts. Not run on its own: the scripts load it with
#   source loadtest/lib-cluster.sh
# and set NS (the namespace) before they call these functions.

# Vote pods per node, one line per node, nodes without a Vote pod included:  "ip-10-0-1-101.ec2.internal 2"
vote_spread() {
  { kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sed 's/^/node /'
    kubectl get pods -n "$NS" -l "${1:-app=vote}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sed 's/^/pod /'
  } | awk '$1 == "node" {c[$2] += 0} $1 == "pod" {c[$2]++} END {for (n in c) print n, c[n]}' | sort
}

# Wait until no Vote pod is shutting down (old pods still count on their node), at most 90 s.
wait_no_terminating() {
  local i
  for i in $(seq 1 90); do
    [ -z "$(kubectl get pods -n "$NS" -l "${1:-app=vote}" -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{end}')" ] && return 0
    sleep 1
  done
  echo "  still Vote pods shutting down after 90 s"; return 1
}

# Even = the busiest and the emptiest node differ by at most 1 Vote pod.
spread_is_even() {
  vote_spread "${1:-app=vote}" | awk 'NR == 1 {min = $2; max = $2} {if ($2 < min) min = $2; if ($2 > max) max = $2} END {exit (max - min <= 1) ? 0 : 1}'
}

# Write where Vote, Redis, PostgreSQL, the Worker and NGINX run into a file, and check the spread.
# Stops the script if the spread is uneven, unless ALLOW_UNEVEN=1 (the uneven run is on purpose).
record_and_check_spread() {
  local file=$1
  wait_no_terminating
  {
    echo "Vote pods per node:"
    vote_spread | sed 's/^/  /'
    echo "Other pods:"
    for ns in "$NS" nginx-gateway; do
      kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | grep -v '^vote-' | sed 's/^/  /'
    done
  } | tee "$file"
  if spread_is_even; then
    echo "  spread: even"
  elif [ "${ALLOW_UNEVEN:-0}" = "1" ]; then
    echo "  spread: UNEVEN, on purpose (ALLOW_UNEVEN=1)"
  else
    echo "  spread: UNEVEN. Stop. Even it out first (./loadtest/make-uneven.sh --restore), or set ALLOW_UNEVEN=1."
    exit 1
  fi
}

# NGINX reloads since a moment (RFC 3339, UTC): each line of NGINX Gateway Fabric's log that says it
# gave NGINX a new configuration. Saves the lines to a file, prints the count.
count_reloads() {
  kubectl logs -n nginx-gateway deploy/nginx-gateway-nginx-gateway-fabric --all-containers --timestamps \
    --since-time="$1" 2>/dev/null | grep 'successfully updated' > "$2" || true
  wc -l < "$2" | tr -d ' '
}
