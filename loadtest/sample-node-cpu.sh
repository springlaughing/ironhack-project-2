# Runs INSIDE a pod: spread-test.sh sends it there with
#   kubectl exec -i <a Vote pod on that node> -- sh -s <seconds> < loadtest/sample-node-cpu.sh
# /proc/stat is not per container: it counts the CPU time of the WHOLE node, since boot, in ticks.
# Once a second, one line: time (UTC), busy ticks, steal ticks, all ticks, number of CPUs.
# The CPU used in a second = (busy now - busy before) / (all now - all before) x CPUs.
# Steal = time the hypervisor gave to another machine: on a t3 instance, a sign of used-up CPU credits.
end=$(( $(date +%s) + $1 ))
ncpu=$(grep -c '^cpu[0-9]' /proc/stat)
echo "time_utc,busy,steal,total,ncpu"
while [ "$(date +%s)" -lt "$end" ]; do
  # cpu  user nice system idle iowait irq softirq steal ...
  set -- $(head -1 /proc/stat)
  busy=$(( $2 + $3 + $4 + $7 + $8 ))
  echo "$(date -u +%T),$busy,$9,$(( busy + $5 + $6 + $9 )),$ncpu"
  sleep 1
done
