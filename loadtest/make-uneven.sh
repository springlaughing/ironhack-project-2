#!/usr/bin/env bash
# Puts the Vote pods 3 + 2 + 1 on purpose, for the spread runs (#9), and back to 2 + 2 + 2.
#   ./loadtest/make-uneven.sh <node>     3 Vote pods on <node> (e.g. ip-10-0-1-249.ec2.internal)
#   ./loadtest/make-uneven.sh --restore  vote.yaml as in Git again: the strict rule, 2 + 2 + 2
# Kubernetes won't place 3 + 2 + 1 by itself: our spread rule forbids it (whenUnsatisfiable:
# DoNotSchedule). So for the uneven run:
#   1. relax the rule to ScheduleAnyway (a pod template change: one update, without load)
#   2. cordon every other node (no NEW pods there; running pods stay)
#   3. delete one Vote pod from the fullest other node: its replacement can only go to <node>
#   4. uncordon the nodes again
set -euo pipefail
cd "$(dirname "$0")/.."
source loadtest/lib-cluster.sh
NS="voting-app"
TARGET="${1:?usage: make-uneven.sh <node> | --restore}"

if [ "$TARGET" = "--restore" ]; then
  # the image the cluster runs; Git has an older tag (the pipeline writes the new one at deploy time)
  IMG=$(kubectl get deploy vote -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
  sed "s|springlaughing/voting-vote:e0035c5|${IMG}|" k8s/app/vote.yaml | kubectl apply -f -
  kubectl rollout status deploy/vote -n "$NS"
  wait_no_terminating
  vote_spread
  exit 0
fi

kubectl get node "$TARGET" > /dev/null   # stops here if the name is wrong
echo "1. spread rule relaxed to ScheduleAnyway (one update)"
kubectl patch deploy vote -n "$NS" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'
kubectl rollout status deploy/vote -n "$NS"
wait_no_terminating
vote_spread

# the other node with the most Vote pods gives one away
FROM=$(vote_spread | awk -v t="$TARGET" '$1 != t {print $2, $1}' | sort -rn | head -1 | awk '{print $2}')
OTHERS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vx "$TARGET")
echo "2. cordon the other nodes"
for n in $OTHERS; do kubectl cordon "$n"; done
trap 'for n in $OTHERS; do kubectl uncordon "$n"; done' EXIT   # whatever happens: uncordon again
echo "3. one Vote pod off ${FROM}: its replacement can only go to ${TARGET}"
POD=$(kubectl get pods -n "$NS" -l app=vote --field-selector "spec.nodeName=${FROM}" -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n "$NS" "$POD"          # waits until it's gone (10 s preStop)
kubectl wait --for=condition=Ready pod -n "$NS" -l app=vote --timeout=120s
echo "4. uncordon (on exit) and the result:"
vote_spread
