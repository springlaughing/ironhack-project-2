# Runs INSIDE the Redis pod: rollout-test.sh sends it there with
#   kubectl exec -i deploy/redis -- sh -s <seconds> < loadtest/sample-queue.sh
# Once a second, one line: time (UTC, the cluster's clock), votes waiting in the queue,
# votes a Worker has taken but not saved yet (its votes:processing:<pod> list).
# The clock runs next to the data, so kubectl's own delay doesn't count.
end=$(( $(date +%s) + $1 ))
echo "time_utc,queue,in_progress"
while [ "$(date +%s)" -lt "$end" ]; do
  p=0
  for k in $(redis-cli --scan --pattern 'votes:processing:*'); do
    p=$(( p + $(redis-cli LLEN "$k") ))
  done
  echo "$(date -u +%T),$(redis-cli LLEN votes),$p"
  sleep 1
done
