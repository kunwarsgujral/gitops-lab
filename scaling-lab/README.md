# Scaling Lab: HPA, PDB, topology spread, descheduler and cluster autoscaler on your desktop

Everything from the interview prep running on one machine, with no cloud and no load balancer:

```
                      your machine
   browser / curl ──► localhost:30080 ──► kind control-plane :30080 (NodePort)
                                              │ kube-proxy
             ┌────────────────────────────────┼────────────────────────────────┐
             ▼                                ▼                                ▼
   scaling-worker  (zone-a)        scaling-worker2 (zone-b)        scaling-worker3 (zone-c)
   NGINX pod(s)                    NGINX pod(s)                    NGINX pod(s)
             ▲ HPA adds/removes pods (CPU via metrics-server)
             ▲ PDB keeps >= 2 up during drains and evictions
             ▲ topology spread places them evenly; descheduler fixes drift later

   kwok-fake-small-xxxx  (fake nodes, created/removed by the real cluster-autoscaler)
   "inflate" pods land here; pending inflate pods => scale-up, empty nodes => scale-down
```

Two kinds of node:
- **3 real workers** (Docker containers run by kind) run NGINX for real. You can curl it, drain nodes and watch rolling updates.
- **Fake nodes** come from **kwok**. A laptop can't buy machines, so the cluster autoscaler's `kwok` provider creates Node *objects* instead, and the kwok controller makes them and their pods look Ready and Running. The scaling *decisions* (when, which group, what blocks removal) are made by the real cluster-autoscaler binary, the same one that runs on AWS, GCP or OpenShift. Only the machines are pretend.

This lab installs everything with plain `helm` on purpose: it's Helm practice, and it's faster to iterate on. Moving it to GitOps later means turning each `helm upgrade --install` into an Argo CD Application with the same values file.

## Prerequisites
- Docker (Docker Desktop, OrbStack, Colima, or Docker on Linux). Give it **at least 6 GB of memory and 4 CPUs**.
- `kind` v0.33+, `kubectl`, `helm` v3.
- Port 30080 free on your machine.
- Works on Apple Silicon and Intel: every image used here is published for both arm64 and amd64.

Fast path: `scripts/up.sh` does steps 1 to 8 setup in one go (about 5 minutes). The steps below do the same thing one piece at a time, with what to look at. Do them by hand at least once.

---

## Step 1: Create the cluster
```bash
cd scaling-lab
kind create cluster --config kind-config.yaml
kubectl get nodes -L topology.kubernetes.io/zone
```
You should see `scaling-control-plane` and three workers in `zone-a`, `zone-b` and `zone-c`.

What `kind-config.yaml` does, and why:
- **Three workers with zone labels**, so topology spread, PDBs and drains behave like a multi-zone cloud cluster. Clouds set `topology.kubernetes.io/zone` on nodes automatically; here it's set by hand.
- **`extraPortMappings` 30080 → 30080** on the control-plane container. This is the "no load balancer" answer: the NGINX Service will be a NodePort on 30080, and kube-proxy on *any* node forwards NodePort traffic to the pods, wherever they run.
- **The node image is pinned to Kubernetes v1.36.4**, because the cluster autoscaler's minor version should match the cluster's (it embeds a copy of the scheduler to simulate placements).

## Step 2: metrics-server
```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --version 3.14.0 -f values/metrics-server.yaml --wait
kubectl top nodes        # may take ~60s before numbers appear
```
**Why:** the HPA doesn't measure anything itself. It reads CPU and memory from the `metrics.k8s.io` API, which metrics-server serves from the kubelets' live stats. metrics-server is *not* Prometheus: it only keeps the last few minutes, just enough for autoscaling and `kubectl top`. The `--kubelet-insecure-tls` flag is needed because kind's kubelet certificates are self-signed (lab only).

## Step 3: Install NGINX and reach it without a load balancer
```bash
helm upgrade --install web oci://registry-1.docker.io/bitnamicharts/nginx \
  -n web --create-namespace --version 22.1.1 -f values/nginx.yaml --wait
```
Read `values/nginx.yaml` top to bottom first. Every block has a comment with what it does and why. Then look at what the chart actually created:
```bash
helm get manifest web -n web | grep '^kind:' | sort | uniq -c
kubectl -n web get deploy,svc,hpa,pdb,networkpolicy,cm
```

**Three ways to reach it (no load balancer needed):**
1. **NodePort plus kind's port mapping** (always on):
   ```bash
   curl -sI http://localhost:30080      # HTTP/1.1 200 OK, Server: nginx
   ```
   Open http://localhost:30080 in a browser too.
2. **`kubectl port-forward`** (temporary, needs no Service changes, and works for anything):
   ```bash
   kubectl -n web port-forward svc/web-nginx 8080:80      # then http://localhost:8080
   ```
3. **The metrics exporter sidecar**, read directly. This is how Prometheus would see NGINX:
   ```bash
   kubectl -n web port-forward svc/web-nginx 9113:9113 &   # the chart adds a "metrics" port to the Service
   curl -s localhost:9113/metrics | grep '^nginx_'
   ```
   You'll see `nginx_up`, `nginx_connections_active` and `nginx_http_requests_total`. That's the stub_status → exporter → Prometheus-format translation we talked through. The Service also carries `prometheus.io/scrape` annotations, and with a Prometheus Operator you'd turn on `metrics.serviceMonitor.enabled` instead.

**Why not `type: LoadBalancer`?** The chart defaults to it, but on kind there's no cloud controller to provision a load balancer, so `EXTERNAL-IP` would stay `<pending>` forever. To try LoadBalancer Services locally later, install **cloud-provider-kind**, which assigns LoadBalancer IPs on kind. For HTTP routing by hostname, the modern choice is a **Gateway API** implementation (Envoy Gateway, NGINX Gateway Fabric, Istio, Cilium and others). The community **ingress-nginx** controller was retired in March 2026, so don't build anything new on it. Mentioning that in an interview shows you're current.

**About the images:** the values file pulls `bitnamilegacy/nginx` and sets `global.security.allowInsecureImages: true`. Since 2025, Bitnami's free versioned images sit in the frozen `bitnamilegacy` repository with no further security updates, and `docker.io/bitnami` serves Bitnami Secure Images. The chart refuses non-Bitnami image paths unless you allow it. The chart version is pinned to 22.1.1 (newer 25.x versions are built for Bitnami Secure Images). Interview line: "In production I'd mirror and scan images into our own registry, pin chart and image versions, and never depend on a vendor's public free tier."

## Step 4: See topology spread working
```bash
scripts/status.sh          # leave this running in its own terminal for the rest of the lab
```
With `minReplicas: 3`, you get **one NGINX pod per zone**. That comes from the two `topologySpreadConstraints` (zone first, then hostname, both `maxSkew: 1`).

Try it with more pods:
```bash
kubectl -n web patch hpa web-nginx -p '{"spec":{"minReplicas":6}}'
# 6 pods -> 2 per zone. Now set it back:
kubectl -n web patch hpa web-nginx -p '{"spec":{"minReplicas":3}}'
```
(Patching live like this is drift. Helm or Argo CD would put it back on the next upgrade or sync. That's fine for an experiment, but in real life you change `values/nginx.yaml`.)

Why `ScheduleAnyway` (soft) rather than `DoNotSchedule` (hard): with a hard rule, losing a zone would leave pods Pending rather than unbalanced. For a stateless web tier, "running but uneven" beats "not running".

## Step 5: HPA: scale pods on load
Terminal 2: `kubectl -n web get hpa web-nginx -w`
Terminal 3:
```bash
kubectl apply -f manifests/loadgen.yaml
```
Within a minute or two, `TARGETS` climbs past `50%` and `REPLICAS` rises toward 9. The new pods spread across zones. The formula the HPA uses:

```
desired replicas = ceil( current replicas × current utilisation / target utilisation )
e.g. 3 × 150% / 50% = 9
```
Utilisation is measured **against the CPU request (50m)**, which is why requests are mandatory for HPA and why the lab sets them explicitly.

Stop the load:
```bash
kubectl -n web delete pod loadgen
```
Replicas take about **5 minutes** to come back down. That's the HPA's default scale-down stabilization window, which stops flapping. Scale-up is immediate on purpose; scale-down is cautious on purpose. If `TARGETS` shows `<unknown>`, metrics-server isn't serving yet: wait a minute, then check `kubectl top pods -n web`.

## Step 6: PDB and graceful shutdown: maintenance without an outage
Terminal 3, keep running:
```bash
scripts/watch-errors.sh        # one request every 0.1s from your machine; prints failures
```

**A drain respects the PDB:**
```bash
NODE=$(kubectl get nodes -l topology.kubernetes.io/zone=zone-a -o jsonpath='{.items[0].metadata.name}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```
The NGINX pod on that node is evicted and rescheduled elsewhere, and `watch-errors.sh` should stay at zero (or near it) failures. `--delete-emptydir-data` is needed because Bitnami NGINX uses emptyDir volumes for its temp files.

**Now make the PDB push back.** Drain zone-b too. That still works, because its pod can move to zone-c. Then try the last worker, where the pods have nowhere to go:
```bash
NODE2=$(kubectl get nodes -l topology.kubernetes.io/zone=zone-b -o jsonpath='{.items[0].metadata.name}')
NODE3=$(kubectl get nodes -l topology.kubernetes.io/zone=zone-c -o jsonpath='{.items[0].metadata.name}')
kubectl drain "$NODE2" --ignore-daemonsets --delete-emptydir-data          # succeeds: pods move to zone-c
kubectl drain "$NODE3" --ignore-daemonsets --delete-emptydir-data --timeout=60s
```
On the last node, the first eviction is allowed (3 ready → 2, still meeting `minAvailable: 2`), but its replacement can't be scheduled anywhere, because every worker is cordoned. The next eviction would leave only 1 ready pod, so you'll see `Cannot evict pod as it would violate the pod's disruption budget`, and the drain keeps retrying until it times out. `watch-errors.sh` keeps showing successes the whole time: the site stays up, and the *maintenance* waits instead. That's exactly the trade-off a PDB encodes. In a real node upgrade, new nodes join, replacement pods become ready there, and the drain continues by itself. Put the nodes back:
```bash
kubectl uncordon "$NODE" "$NODE2" "$NODE3"
```
Notice that the pods **don't move back** on their own after you uncordon. The scheduler only places pods when they're created. Remember that for step 7.

**Rolling update with zero dropped requests:**
```bash
kubectl -n web rollout restart deploy/web-nginx
kubectl -n web rollout status deploy/web-nginx
```
Watch `watch-errors.sh` during the rollout. The `preStop: sleep 5` hook keeps each old pod serving while kube-proxy stops routing to it: endpoint removal and SIGTERM happen *in parallel*, and the sleep covers the gap. To compare, remove the hook and roll again:
```bash
helm upgrade web oci://registry-1.docker.io/bitnamicharts/nginx -n web --version 22.1.1 \
  -f values/nginx.yaml --set-json 'lifecycleHooks={}'
kubectl -n web rollout restart deploy/web-nginx
```
On a laptop the race is short and you may still see 0 errors. On busy production clusters with many nodes, it's where "a few 502s on every deploy" comes from. Run the first `helm upgrade` command without `--set-json` to restore the hook.

## Step 7: Descheduler: fix placement drift
The descheduler is running in **dry-run** mode: it logs what it *would* evict and does nothing.

**Create drift:**
```bash
Z3=$(kubectl get nodes -l topology.kubernetes.io/zone=zone-c -o jsonpath='{.items[0].metadata.name}')
kubectl cordon "$Z3"
kubectl -n web rollout restart deploy/web-nginx && kubectl -n web rollout status deploy/web-nginx
kubectl uncordon "$Z3"
```
All NGINX pods are now in zone-a and zone-b, and zone-c is empty. That's a topology spread violation, but the scheduler won't fix it, because nothing is being scheduled.

**Read the dry-run decisions** (it runs every minute):
```bash
kubectl -n kube-system logs deploy/descheduler -f | grep -i -E "evict|topology|duplicate"
```
Look for lines naming NGINX pods it would evict because of `RemovePodsViolatingTopologySpreadConstraint` or `RemoveDuplicates`.

**Let it act:**
```bash
helm upgrade descheduler descheduler/descheduler -n kube-system --version 0.37.0 \
  -f values/descheduler.yaml --set cmdOptions.dry-run=false
```
Within a minute or two, it evicts the excess pods from zone-a or zone-b. The Deployment recreates them, and the scheduler, following the spread constraints, places them in zone-c. Keep `watch-errors.sh` running: evictions go through the **eviction API**, so the PDB keeps at least 2 pods up throughout. The descheduler *never picks the destination*; it only decides who leaves, and the scheduler does the rest.

Why it's a separate add-on and not built in: moving running pods is disruptive. Kubernetes keeps placement (scheduler) and correction (descheduler) separate, so correction is opt-in, rate-limited and PDB-aware. Production practice: run it in dry-run for a while, review the logs, then enable it on a conservative interval.

## Step 8: Cluster autoscaler: add and remove nodes
Install kwok and the autoscaler (skip this if you used `up.sh`):
```bash
kubectl apply -f https://github.com/kubernetes-sigs/kwok/releases/download/v0.8.0/kwok.yaml
kubectl apply -f https://github.com/kubernetes-sigs/kwok/releases/download/v0.8.0/stage-fast.yaml
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system \
  --version 9.59.0 -f values/cluster-autoscaler.yaml
kubectl apply --server-side --force-conflicts -f manifests/kwok-node-template.yaml
kubectl -n kube-system rollout restart deploy/cluster-autoscaler
kubectl create namespace autoscale-test
kubectl apply -f manifests/inflate.yaml
```
What these pieces are:
- **`kwok.yaml`** is the kwok controller. It takes ownership of any Node annotated `kwok.x-k8s.io/node: fake` and keeps it "Ready". **`stage-fast.yaml`** tells it to move pods scheduled there to Running immediately.
- **`kwok-node-template.yaml`** defines the node group: a "small" node with 4 CPU / 8 Gi, between 0 and 5 nodes. On a cloud this would be an Auto Scaling Group, a managed node group or a MachineSet.
- **`values/cluster-autoscaler.yaml`** uses the real autoscaler with `--cloud-provider=kwok`, shorter scale-down timers (1 minute instead of 10) so you can watch it, and the `least-waste` expander. Note the gotcha in that file: without `autoDiscovery.clusterName`, the chart silently renders no Deployment.
- **`inflate`** is a do-nothing workload that requests 1 CPU / 1 Gi per pod and may only run on the fake node group (toleration for the `kwok-provider` taint plus a nodeSelector). It starts at 0 replicas.

Check it registered the node group:
```bash
kubectl -n kube-system logs deploy/cluster-autoscaler | grep -i -E "node ?group|small" | tail -5
```

**Scale-up** (terminal 2: `kubectl get nodes -w`):
```bash
kubectl -n autoscale-test scale deploy/inflate --replicas=3
kubectl -n autoscale-test get events --sort-by=.lastTimestamp | grep -i -E "scale|FailedScheduling" | tail
```
1. The 3 pods go **Pending**: no node fits, because the real workers don't match the nodeSelector.
2. The autoscaler sees *unschedulable pods*, simulates which node group would fit them, and adds a node. The pods get a `TriggeredScaleUp` event.
3. `kwok-fake-small-…` appears and turns Ready, and the pods go Running.
4. One node holds 3 pods: 4 CPU, minus the DaemonSets that also "run" there, leaves room for three 1-CPU pods.

Scale further: `--replicas=10` gives 4 nodes. Then `--replicas=20`: the group stops at its **max of 5 nodes** and the remaining pods stay Pending with a `NotTriggerScaleUp` event (`max node group size reached`). That's the scenario you alert on in production ("pods pending for more than 10 minutes"). Nothing else tells you the autoscaler hit its ceiling.

Key point to say in the interview: **the trigger is Pending pods and resource *requests*, not CPU usage.** These pods use zero CPU, but they request 1 CPU each, so they need nodes.

**Scale-down:**
```bash
kubectl -n autoscale-test scale deploy/inflate --replicas=0
```
After about a minute (`scale-down-unneeded-time: 1m` here, 10 minutes by default), empty fake nodes are removed. The autoscaler logs show why each node was considered unneeded (below the 50% requested-utilisation threshold).

**What blocks scale-down (the classic troubleshooting question).** Make it happen:
```bash
kubectl -n autoscale-test scale deploy/inflate --replicas=4      # -> 2 nodes: 3 pods + 1 pod
kubectl -n autoscale-test create pdb inflate-pdb --selector=app=inflate --max-unavailable=0
kubectl -n autoscale-test scale deploy/inflate --replicas=3      # wait ~1 min
kubectl -n kube-system logs deploy/cluster-autoscaler | grep -i -E "not removable|disruption|pdb" | tail
```
With 3 replicas, the pods could fit on one node. (Scaling a Deployment down deletes pods directly, not through evictions, so the PDB doesn't stop that, and the ReplicaSet removes a pod from the fuller node first.) That leaves one node holding a single pod at about 25% requested, which is a removal candidate. But moving that pod needs an eviction, and the PDB allows zero, so the autoscaler logs the node as **not removable** because of the pod disruption budget. Other blockers work the same way: pods with the annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, bare pods with no controller, pods with local storage (by default), and `kube-system` pods without a PDB. Clean up:
```bash
kubectl -n autoscale-test delete pdb inflate-pdb
kubectl -n autoscale-test scale deploy/inflate --replicas=0
```
(kwok limitation to know: it deletes fake nodes without draining them. Real providers drain first. The *decision* logic is still the real one.)

## Step 9: Overprovisioning: hide node boot time
On a real cloud, a new node takes minutes, and pods wait the whole time. The fix is spare capacity held by placeholder pods with negative priority:
```bash
kubectl apply -f manifests/overprovisioning.yaml        # 2 placeholder pods -> 1 node is added for them
kubectl -n autoscale-test scale deploy/inflate --replicas=2
kubectl -n autoscale-test get events --sort-by=.lastTimestamp | grep -i preempt
```
The `inflate` pods start **immediately**: the scheduler *preempts* the placeholders (priority -10 loses to the default 0). The placeholders go Pending, which makes the autoscaler add a node in the background to restore the buffer. You pay for idle capacity, and in return real pods never wait for a boot. The size of that buffer is a cost vs latency decision. Clean up with `kubectl delete -f manifests/overprovisioning.yaml`.

## Step 10: The whole story in one breath
- **Placement:** topology spread puts pods across zones and nodes at scheduling time.
- **Pods:** the HPA (or KEDA) changes the *number of pods* from live metrics, using metrics-server here.
- **Nodes:** the cluster autoscaler (or Karpenter) changes the *number of nodes* when pods are Pending, based on resource *requests*.
- **Drift:** the descheduler corrects placement that has drifted over time.
- **Safety:** PDBs keep every voluntary disruption (drains, descheduler and autoscaler evictions) from taking a service below its minimum, and preStop plus graceful shutdown keep rollouts from dropping requests.
- **Headroom:** overprovisioning trades a little cost for no waiting.
- **Access:** without a load balancer, it's NodePort plus a port mapping or `port-forward`. In production it's a LoadBalancer Service or a Gateway API implementation.

## Clean up
```bash
scripts/down.sh            # deletes the kind cluster; nothing else on your machine changes
```

## Troubleshooting
| Symptom | Likely cause and fix |
|---|---|
| `curl localhost:30080` refused | The cluster wasn't created with `kind-config.yaml` (no port mapping), the Service isn't NodePort 30080 (`kubectl -n web get svc`), or something else uses port 30080. |
| NGINX pods `ImagePullBackOff` | Image path or tag typo, or Docker Hub rate limits. Check `kubectl -n web describe pod`. The tags in `values/nginx.yaml` exist in `bitnamilegacy` as of October 2026. |
| Helm says images "substituted for unrecognized ones" | `global.security.allowInsecureImages: true` is missing. |
| HPA `TARGETS` shows `<unknown>` | metrics-server not ready yet (wait about 60s) or not installed (`kubectl top nodes`). |
| No `cluster-autoscaler` Deployment | `autoDiscovery.clusterName` missing from its values (the chart silently skips the Deployment). |
| Fake nodes appear but stay NotReady | The kwok controller or `stage-fast.yaml` isn't applied: `kubectl -n kube-system get deploy kwok-controller`. |
| inflate pods Pending, no scale-up | Check `kubectl -n autoscale-test describe pod` events, and the autoscaler logs. The node template ConfigMap may still hold the chart's samples: re-apply `manifests/kwok-node-template.yaml`, then restart the autoscaler. |
| Everything slow or pods Pending on real workers | Docker has too little memory or CPU; give it 6 GB+ and 4 CPUs. |

## What was and wasn't verified
These files were written against the upstream sources, read directly in October 2026:
- the Bitnami NGINX chart 22.1.1 values and templates,
- cluster-autoscaler chart 9.59.0 and the v1.36.1 kwok provider code,
- descheduler chart 0.37.0 and its plugin argument types,
- kind v0.33.0 node images and kwok v0.8.0.

Every values key and command-line flag used was checked against them, and the image tags were checked on Docker Hub. The lab has **not** been run end to end on a real machine (the environment it was built in has no Docker), so expect to fix a small thing or two on the first run. Treat whatever breaks as interview material.
