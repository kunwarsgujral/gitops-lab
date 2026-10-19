#!/usr/bin/env bash
# Builds the whole scaling lab in one go (the README walks through the same steps one at a time,
# which is the better way to learn it; use this script to rebuild quickly after `down.sh`).
#
# Prereqs: docker (Docker Desktop / OrbStack / Colima / Linux), kind >= v0.33, kubectl, helm v3.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned versions (checked October 2026). Change deliberately, not by accident.
NGINX_CHART_VERSION=22.1.1            # oci://registry-1.docker.io/bitnamicharts/nginx
METRICS_SERVER_CHART_VERSION=3.14.0   # https://kubernetes-sigs.github.io/metrics-server/
DESCHEDULER_CHART_VERSION=0.37.0      # https://kubernetes-sigs.github.io/descheduler/
CA_CHART_VERSION=9.59.0               # https://kubernetes.github.io/autoscaler
KWOK_VERSION=v0.8.0                   # https://github.com/kubernetes-sigs/kwok/releases

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "1/7 kind cluster: 1 control plane + 3 workers in zone-a/b/c, port 30080 mapped to localhost"
kind get clusters | grep -qx scaling || kind create cluster --config kind-config.yaml
kubectl config use-context kind-scaling >/dev/null
kubectl get nodes -L topology.kubernetes.io/zone

step "2/7 Helm repos"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/ >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo update >/dev/null

step "3/7 metrics-server (feeds the HPA and kubectl top)"
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --version "$METRICS_SERVER_CHART_VERSION" -f values/metrics-server.yaml --wait

step "4/7 NGINX (Bitnami chart) in namespace web: HPA, PDB, topology spread, NodePort 30080"
helm upgrade --install web oci://registry-1.docker.io/bitnamicharts/nginx -n web --create-namespace \
  --version "$NGINX_CHART_VERSION" -f values/nginx.yaml --wait --timeout 5m

step "5/7 descheduler (dry-run mode to start)"
helm upgrade --install descheduler descheduler/descheduler -n kube-system \
  --version "$DESCHEDULER_CHART_VERSION" -f values/descheduler.yaml --wait

step "6/7 kwok controller (makes fake nodes and their pods look Ready/Running)"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"
kubectl -n kube-system rollout status deploy/kwok-controller --timeout=3m

step "7/7 cluster autoscaler (kwok provider) + our node template + test workloads"
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system \
  --version "$CA_CHART_VERSION" -f values/cluster-autoscaler.yaml
# Replace the chart's sample node templates with ours, then restart so the provider re-reads them.
kubectl apply --server-side --force-conflicts -f manifests/kwok-node-template.yaml
kubectl -n kube-system rollout restart deploy/cluster-autoscaler
kubectl -n kube-system rollout status deploy/cluster-autoscaler --timeout=3m
kubectl create namespace autoscale-test --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/inflate.yaml

cat <<'EOF'

Ready.
  Site:        curl -sI http://localhost:30080       (or open it in a browser)
  Everything:  scripts/status.sh
  Next:        README.md, step 3 onwards
EOF
