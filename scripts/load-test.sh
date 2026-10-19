#!/usr/bin/env bash
# Generates in-cluster load against demo-app so KEDA scales it up.
#   scripts/load-test.sh          start load
#   scripts/load-test.sh stop     remove load generator
# The load generator is a policy-compliant Pod (scripts/loadgen.yaml); see the comment there.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "stop" ]]; then
  kubectl delete -f loadgen.yaml --ignore-not-found
  exit 0
fi

kubectl apply -f loadgen.yaml

echo "Load started. In other terminals:"
echo "  kubectl -n demo get hpa,scaledobject -w"
echo "  kubectl -n demo get pods -w"
echo "Then run: $0 stop   (replicas return to 1 after the HPA's ~5 minute scale-down window)"
