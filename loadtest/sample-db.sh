# Runs INSIDE the PostgreSQL pod: rollout-test.sh sends it there with
#   kubectl exec -i deploy/postgres -- sh -s <RUN> <seconds> < loadtest/sample-db.sh
# Once a second, one line: time (UTC, the cluster's clock), this run's votes saved so far.
run=$1
end=$(( $(date +%s) + $2 ))
echo "time_utc,saved"
while [ "$(date +%s)" -lt "$end" ]; do
  echo "$(date -u +%T),$(psql -U postgres -tAc "SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-${run}-%'")"
  sleep 1
done
