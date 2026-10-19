#!/usr/bin/env bash
# Prints the latest chart versions so you can pin targetRevision in apps/*.yaml.
# "targetRevision: *" is fine for a first run; pinned versions are what you defend in an interview.
set -euo pipefail

helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null

for chart in kyverno/kyverno external-secrets/external-secrets prometheus-community/kube-prometheus-stack kedacore/keda stakater/reloader; do
  helm search repo "${chart}" --output json | python3 -c "
import json, sys
r = json.load(sys.stdin)[0]
print(f\"{r['name']:50s} chart {r['version']:12s} app {r['app_version']}\")"
done
