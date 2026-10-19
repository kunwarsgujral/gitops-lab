# GitOps Lab: Helm + Argo CD + Prometheus/Grafana + KEDA + ESO + Kyverno + GitHub Actions

A single repo you can run on a laptop (kind) and explain end to end in an interview.

```
 git push ──► GitHub Actions (CI only)
                 │  helm lint → helm template | kubeconform → kyverno apply + kyverno test
                 │  docker build → push ghcr.io/<you>/demo-app:<sha>
                 │  commit new image.tag to charts/demo-app/values.yaml
                 ▼
              Git (single source of truth)
                 ▲  Argo CD polls/pulls and reconciles (prune + selfHeal)
                 │
   ┌─────────────┴──────────────── kind cluster ──────────────────────────────┐
   │ Argo CD ── root app ── wave -3  kyverno (admission controller + CRDs)    │
   │                        wave -2  external-secrets (operator + CRDs)       │
   │                        wave -1  eso-config, kyverno-policies             │
   │                        wave  0  kube-prometheus-stack, keda, reloader    │
   │                        wave  1  demo-app (your chart)                    │
   │                                                                          │
   │ secret store ─► ESO ─► K8s Secret ─► Grafana admin / demo-app env        │
   │ demo-app /metrics ─► ServiceMonitor ─► Prometheus ─► Grafana             │
   │ Prometheus ◄─ KEDA ScaledObject (query) ─► HPA ─► demo-app replicas      │
   │ every create/update in a tenant namespace ─► Kyverno admission check     │
   └──────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites
`docker`, `kind`, `kubectl`, `helm` (v3), and a GitHub repo for this code (public is easiest; private needs repo credentials in Argo CD).

## Quick start
```bash
# 1. Push this folder to github.com/<you>/gitops-lab (repo name must match, or edit the URLs)
# 2. Optional but recommended: pin chart versions (replaces targetRevision "*")
scripts/pin-versions.sh
# 3. Create the cluster, install Argo CD with Helm, apply the root app
scripts/bootstrap.sh <your-github-user>
```
The first push to `main` after that runs CI, builds the image, and commits the tag. Make the GHCR package public (or add an `imagePullSecret`) so the cluster can pull it.

## Layout
| Path | What it is |
|---|---|
| `bootstrap/root-app.yaml` | App-of-apps root. The only thing applied by hand. |
| `bootstrap/argocd-values.yaml` | Argo CD Helm values: restores the Application health check so sync waves really wait. |
| `apps/` | One Argo CD `Application` per component, ordered with sync waves. |
| `platform/eso-config/` | Namespaces, `ClusterSecretStore` (Fake provider), Grafana `ExternalSecret`. |
| `platform/kyverno-policies/` | Kyverno CEL policies: `policies/` (4 `ValidatingPolicy`), `generate/` (namespace quota + limits), `rbac.yaml` (aggregated permissions for Kyverno's controllers). |
| `tests/kyverno/` | `kyverno test` unit tests for the policies, with good and bad sample resources. |
| `scripts/loadgen.yaml` | Policy-compliant load generator Pod used by `scripts/load-test.sh`. |
| `charts/demo-app/` | Your Helm chart: Deployment, Service, ServiceMonitor, PrometheusRule, Grafana dashboard ConfigMap, ScaledObject, ExternalSecret, Argo CD hooks. |
| `docs/runbooks/demo-app.md` | Runbook for every demo-app alert (linked from each alert's `runbook_url`). |
| `app/` | The demo service (Python, exposes `/metrics`) and Dockerfile. |
| `.github/workflows/ci.yaml` | CI: lint, render, validate, Kyverno policy check and tests, build, push, bump tag. |
| `.github/workflows/aws-oidc-example.yaml` | Keyless AWS auth via OIDC (talking point, manual trigger). |
| `docs/examples/` | AWS Secrets Manager store, the "real backend" version. |
| `INTERVIEW_QA.md` | Mock interview questions and answers, plus troubleshooting scenarios. |
| `scaling-lab/` | Separate, standalone lab: Bitnami NGINX with HPA, PDB, topology spread, descheduler and the cluster autoscaler (fake nodes via kwok), all reachable on localhost with no load balancer. See `scaling-lab/README.md`. |

## Practice drills
Do these in order, and say each result out loud as you go.

**Helm**
1. `helm template demo-app charts/demo-app | less`, then `helm lint charts/demo-app`.
2. Override a value: `helm template demo-app charts/demo-app --set keda.enabled=false` and find what changed (the Deployment gets `replicas`).
3. Break `_helpers.tpl` on purpose and read the error. Fix it.
4. Install it by hand in a scratch namespace: `helm upgrade --install demo charts/demo-app -n scratch --create-namespace`, then `helm history`, change a value, upgrade, and `helm rollback demo 1`. (Then explain why you would not do this on an Argo-managed release.)
5. Optional: `helm plugin install https://github.com/databus23/helm-diff` and run `helm diff upgrade`.

**Argo CD**
1. Watch the waves: `kubectl -n argocd get applications -w`. Explain why ESO is wave -2.
2. Self-heal: `kubectl -n demo delete deploy demo-app` and watch it return. Then `kubectl -n demo scale deploy demo-app --replicas=5` and ask why Argo does *not* revert that (the `ignoreDifferences` on replicas, and KEDA owns it).
3. Rollback: push a bad change, `git revert` it, watch the sync. Then try `argocd app rollback` with auto-sync on and read the error.
4. Hooks (`charts/demo-app/templates/hooks.yaml`):
   - After a sync, `kubectl -n demo get jobs` shows the `PostSync` smoke test. Read its logs.
   - Break it: change the smoke test path to `/nope`, push, and watch the sync go Failed and the `SyncFail` notifier run. Then revert.
   - Set `hooks.preSyncMigration.enabled: true` and confirm the migration Job finishes *before* the Deployment changes. Make it `exit 1` and confirm the old pods keep running.
   - Explain why these use Argo annotations and not `helm.sh/hook` (Argo renders with `helm template`; Helm hooks get mapped to sync phases and run on every sync).
5. Turn on `ServerSideApply` for one app, remove it, and see what breaks for kube-prometheus-stack (oversized CRD annotations).

**ESO**
1. `kubectl -n monitoring get externalsecret,secret grafana-admin` and read `.status.conditions`.
2. Rotation: change `/demo/api-key` in `10-clustersecretstore.yaml`, push, wait one `refreshInterval`, then watch the Secret update and Reloader roll the demo-app pods (`kubectl -n demo get pods -w`).
3. Break it: reference a key that does not exist and read the `SecretSyncedError`.
4. Read `docs/examples/aws-secretsmanager-clustersecretstore.yaml` and explain what changes when you move to a real backend (only the store).

**Prometheus, Grafana, KEDA**
1. `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090` → Status → Targets. Find `demo-app`.
2. Run `sum(rate(demo_app_http_requests_total[1m]))` in Prometheus, then `histogram_quantile` and `rate` variants on any other metric.
3. `scripts/load-test.sh`, then watch `kubectl -n demo get hpa,scaledobject -w`. Replicas should climb toward 8. After `scripts/load-test.sh stop` they fall back to 1 in about 5 minutes. That delay is the HPA's default scale-down stabilization window; `cooldownPeriod` only applies to scaling to zero. Explain the difference.
4. Log into Grafana (user `admin`, password from the store) and open the dashboard "Demo App: RED, SLO, scaling". It comes from `charts/demo-app/dashboards/demo-app.json` through a ConfigMap the Grafana sidecar loads. Change a panel in the JSON, push, and watch Grafana pick it up without a restart.
5. Prometheus UI > Status > Rule health: find the `demo-app.recording` and `demo-app.alerts` groups. If they're missing, read the `ruleSelectorNilUsesHelmValues` comment in `apps/30-monitoring.yaml`.
6. **Alert drill (error budget):** set `app.errorRate: "0.2"` in `values.yaml`, push, and run `scripts/load-test.sh`. Watch Alerts in the Prometheus UI: `DemoAppErrorBudgetBurnFast` goes *pending*, then *firing* after its `for: 2m`. See it in Alertmanager (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093`) and create a silence. Follow the runbook link in the alert. Revert in Git.
7. **Alert drill (latency):** set `app.extraLatencyMs: "1500"`, push, load, and watch `DemoAppHighLatencyP95` plus the latency panel. Explain why p50 and p95 move differently.
8. **Alert drill (target down):** pause KEDA at zero replicas with `kubectl -n demo annotate scaledobject demo-app autoscaling.keda.sh/paused-replicas=0`. Scaling the Deployment by hand doesn't work, because KEDA would scale it straight back up. Watch `DemoAppTargetDown` fire through the `absent()` branch, then remove the annotation (`autoscaling.keda.sh/paused-replicas-`).
9. Explore the built-in kube-prometheus-stack dashboards ("Kubernetes / Compute Resources / Namespace (Pods)") and alerts (`KubePodCrashLooping`, `KubeContainerWaiting`), so you know what comes for free.

**Kyverno** (policies in `platform/kyverno-policies/`)
1. See what's enforced: `kubectl get validatingpolicies,generatingpolicies` and `kubectl -n demo get resourcequota,limitrange` (generated by `namespace-guardrails`).
2. Get denied: `kubectl -n demo run t --image=nginx:1.27`. Read the messages: `require-non-root` and `require-requests-limits` block it. Notice it does *not* complain about memory: the generated LimitRange filled in memory defaults first, because the built-in LimitRanger runs before Kyverno's webhook. Then try the same with a Deployment (`kubectl -n demo create deployment t --image=nginx:1.27`) and see that it's rejected at the Deployment, thanks to autogen.
3. Audit mode: `kubectl get policyreport -n demo`. Before CI's first run, the demo-app Deployment shows a `disallow-latest-tag` failure because its tag is still `latest`, yet it deployed fine. That's Audit vs Deny. Once CI commits a real tag, the report turns to pass.
4. Generate + synchronize: `kubectl create namespace team-a`, check its quota appears, delete the quota, and watch Kyverno recreate it.
5. The ESO guardrail: in `team-a`, apply an ExternalSecret that references `ClusterSecretStore lab-store` and read the denial. Then switch it to `kind: SecretStore` and see it pass the policy.
6. Exception: write a `PolicyException` (`policies.kyverno.io/v1`) that lets one named Pod in `team-a` skip `require-non-root`, and explain who should be allowed to create exceptions and where.
7. Shift left: run `helm template demo-app charts/demo-app > /tmp/r.yaml`, stamp the namespace (`yq -i '.metadata.namespace = "demo"' /tmp/r.yaml`), then `kyverno apply platform/kyverno-policies/policies/ --resource /tmp/r.yaml --audit-warn` and `kyverno test tests/kyverno/`. Same answers as the cluster, before you push.
8. Failure mode: `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=0`, then try to create a pod in `demo` and read the webhook error. Then watch Argo CD's self-heal scale Kyverno back up, and explain the failurePolicy trade-off. (Check the deployment name with `kubectl -n kyverno get deploy`.)

**CI**
1. Open a PR that breaks the chart (bad indent) and watch `validate` fail. Then open one that removes `resources` from the Deployment and watch the Kyverno step fail with the policy message.
2. Merge a change under `app/` and follow it all the way: Action → GHCR → bot commit → Argo sync → new pods.
3. Read `aws-oidc-example.yaml` and explain the trust policy `sub` condition.

## Known limits (read before the interview)
- **Fake secret store is lab-only.** The "secret" values sit in Git. A real setup keeps them in AWS Secrets Manager, Vault, or similar, which is exactly what ESO is for.
- **Versions are unpinned (`"*"`)** until you run `scripts/pin-versions.sh`. Pin them; being able to say why is part of the answer.
- **The chart was rendered with Go's template engine plus the Helm functions it uses, not with the real Helm binary** (Helm couldn't be downloaded in the environment this was built in). The output parsed as valid Kubernetes YAML with KEDA both on and off. Still run `helm lint charts/demo-app` locally; CI (`helm lint` + `kubeconform`) is the full check.
- The PromQL in the alerts and dashboard was checked by hand, not with `promtool`. If a rule fails to load, Prometheus UI > Status > Rule health shows the error.
- The dashboard and alerts assume the release is named `demo-app` (which is what Argo CD uses here), because the job label is the Service name.
- The `ignoreDifferences` entries for ESO and KEDA cover the usual CA-bundle noise. If Argo CD still shows a permanent diff on your versions, `argocd app diff <name>` will show the field to add.
- The ESO manifests use the `external-secrets.io/v1` API, which needs a current ESO release.
- **Kyverno policies use the CEL policy types (`policies.kyverno.io/v1`), which need Kyverno 1.17 or newer.** The classic `ClusterPolicy` kind is deprecated since 1.19, and 1.20 blocks creating new ones, so don't copy older `ClusterPolicy` examples into this repo.
- **The Kyverno policies and tests were not run against a real Kyverno** (the Kyverno CLI couldn't be built or downloaded where this was made). They were checked against Kyverno's v1 CRD schemas, and their logic was simulated against the test resources and the rendered chart. CI's `kyverno apply` and `kyverno test` steps are the first real run. If a CEL expression fails to compile, the policy's status shows it: `kubectl get validatingpolicy <name> -o yaml`.
- Kyverno runs with a single admission-controller replica here, so if it's down, pod creation in tenant namespaces fails (drill 8). Production needs 3+ replicas and a PodDisruptionBudget.
