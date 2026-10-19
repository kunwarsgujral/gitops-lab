# demo-app runbook

Every alert in `charts/demo-app/templates/prometheusrule.yaml` links to a section here through its `runbook_url` annotation. A good runbook answers four questions fast: what it means, how bad it is, how to confirm it, and what to do.

Useful commands for every alert:
```bash
kubectl -n demo get pods,hpa,scaledobject
kubectl -n demo logs deploy/demo-app --tail=100
kubectl -n argocd get application demo-app        # did a sync just happen?
git log --oneline -5 -- charts/demo-app            # what changed in Git?
```

## DemoAppErrorBudgetBurnFast
**Meaning:** more than 1.44% of requests (14.4 x the 0.1% budget) have failed over both the last 1h and the last 5m. At this rate the 30-day error budget is gone in about 2 days.
**Severity:** critical, page.
**Confirm:** Grafana dashboard "Demo App: RED, SLO, scaling", panel "Requests per second by status code". Is it 5xx, and from all pods or one?
**Act:**
1. If it started right after a sync, roll back with `git revert` of the last change to `charts/demo-app` and let Argo CD sync.
2. If one pod is bad, delete it and let the Deployment replace it.
3. If it's a dependency, check that the `API_KEY` Secret is present (`kubectl -n demo get externalsecret`).
4. In this lab, check `app.errorRate` in `values.yaml`. That is the injected failure.

## DemoAppErrorBudgetBurnSlow
**Meaning:** more than 0.6% errors (6x budget) over 6h and 30m. Not an emergency, but it will exhaust the budget within the window if it continues.
**Severity:** warning, ticket.
**Act:** find the error pattern during working hours, and consider freezing risky releases until the burn rate drops.

## DemoAppHighLatencyP95
**Meaning:** the 95th percentile request latency has been above the threshold for 5 minutes.
**Confirm:** dashboard "Latency percentiles". Did p50 move too (everything is slower), or only p95/p99 (a tail problem)? Check "CPU usage per pod" for throttling and "Replicas" for being at max.
**Act:** if replicas are at max, raise `keda.maxReplicaCount`. If CPU is at the limit, raise the limits or requests. In this lab, check `app.extraLatencyMs`.

## DemoAppTargetDown
**Meaning:** Prometheus has no healthy scrape target for demo-app, or the metric disappeared entirely.
**Severity:** critical. Either the app is down, or you are flying blind.
**Confirm:** Prometheus UI > Status > Targets. If pods are running but the target is missing, the problem is the ServiceMonitor (selector labels, port name) or the Service, not the app.
**Act:** `kubectl -n demo get pods` for crashloops and `kubectl -n demo describe pod` for events. Check the Argo CD app health.

## DemoAppAtMaxReplicas
**Meaning:** KEDA's HPA has been at `maxReplicaCount` for 15 minutes, so the app cannot absorb more load.
**Severity:** warning.
**Act:** confirm the load is real (request-rate panel) and not a retry storm. Raise `keda.maxReplicaCount` through Git, and check that the nodes have room (`kubectl top nodes`, pending pods).
