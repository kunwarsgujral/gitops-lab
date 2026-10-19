#!/usr/bin/env bash
# Usage: scripts/bootstrap.sh <github-user>
# Creates a kind cluster, installs Argo CD with Helm, and applies the root app-of-apps.
# Prereqs: docker, kind, kubectl, helm. Your repo must be pushed to GitHub (public, or add repo creds in Argo CD).
set -euo pipefail

GH_USER="${1:?usage: $0 <github-user>}"
cd "$(dirname "$0")/.."

echo ">> Pointing manifests at github.com/${GH_USER}/gitops-lab"
grep -rl YOUR_GITHUB_USER apps bootstrap charts | xargs sed -i "s/YOUR_GITHUB_USER/${GH_USER}/g"
echo "   Commit and push these changes before continuing (Argo CD reads from Git, not your disk)."
read -r -p "   Pushed? [y/N] " ok
[[ "${ok}" == "y" ]] || exit 1

echo ">> Creating kind cluster"
kind get clusters | grep -qx lab || kind create cluster --name lab

echo ">> Installing Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait \
  -f bootstrap/argocd-values.yaml

echo ">> Applying root app-of-apps"
kubectl apply -f bootstrap/root-app.yaml

cat <<'EOF'

Done. Next:
  Argo CD UI:   kubectl -n argocd port-forward svc/argocd-server 8080:443   (https://localhost:8080, user: admin)
  Admin pass:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  Grafana:      kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  Watch apps:   kubectl -n argocd get applications -w
EOF
