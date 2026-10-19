#!/usr/bin/env bash
# One-screen view of everything the lab is about, refreshed every 3 seconds. Ctrl-C to exit.
# Uses a loop instead of `watch` so it also works on macOS without extra installs.
set -uo pipefail
while true; do
  clear
  date
  echo "--- nodes (zone, and kwok node group for fake nodes)"
  kubectl get nodes -L topology.kubernetes.io/zone,kwok-nodegroup --no-headers 2>/dev/null
  echo; echo "--- web: HPA and PDB"
  kubectl -n web get hpa,pdb --no-headers 2>/dev/null
  echo; echo "--- web: NGINX pods and the node each runs on"
  kubectl -n web get pods -l app.kubernetes.io/instance=web -o wide --no-headers 2>/dev/null \
    | awk '{printf "%-36s %-10s %s\n", $1, $3, $7}'
  echo; echo "--- autoscale-test: inflate / overprovisioning pods"
  kubectl -n autoscale-test get pods -o wide --no-headers 2>/dev/null \
    | awk '{printf "%-36s %-10s %s\n", $1, $3, $7}'
  echo; echo "--- CPU (metrics-server)"
  kubectl top pods -n web --no-headers 2>/dev/null | head -12
  sleep 3
done
