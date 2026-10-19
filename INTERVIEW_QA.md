# Interview Q&A: GitOps with Helm, Argo CD, ESO, Kyverno, GitHub Actions, KEDA, Prometheus/Grafana on Kubernetes

Practice answering out loud in 30 to 60 seconds each. Answers here are the skeleton; add one real detail from the lab to each.

## The 60-second story
"CI and CD are separate. GitHub Actions does CI: it lints and validates the Helm chart, builds the image, pushes it to a registry, and commits the new image tag to the GitOps repo. Argo CD does CD by pulling from that repo and reconciling the cluster, with self-heal and prune, so Git is the source of truth and the cluster credentials never leave the cluster. Secrets never touch Git: External Secrets Operator syncs them from a vault into Kubernetes Secrets, and Reloader rolls pods when they rotate. Prometheus and Grafana give visibility: each app ships its own ServiceMonitor, SLO burn-rate alerts with runbook links, and a dashboard as code. KEDA scales the app on a Prometheus query instead of CPU. Kyverno enforces guardrails at admission, such as resource limits, non-root containers, pinned image tags and a quota for every tenant namespace, and the same policies run in CI against the rendered chart. Rollback is a Git revert."

## GitOps and Argo CD
**Push vs pull deploys?**
Push (a pipeline runs `kubectl`/`helm` against the cluster) needs cluster credentials in CI and has no drift detection. Pull (Argo CD inside the cluster) keeps credentials in the cluster, continuously compares live state to Git, and can self-heal.

**What is app-of-apps and why use it?**
One root Application that points at a folder of Application manifests. It gives you a single bootstrap command and lets you declare the whole platform in Git. ApplicationSets are the alternative when you generate many similar apps (per cluster, per environment).

**How do sync waves work?**
Resources (or child Applications) with lower wave numbers sync first, and Argo waits for them to be Healthy before the next wave. I used -2 for the ESO operator, -1 for the store and ExternalSecrets, 0 for monitoring and KEDA, and 1 for the app, because each depends on CRDs or objects from the one before.
Follow-up that catches people out: since Argo CD 1.8, Argo doesn't assess the health of `Application` resources by default. In app-of-apps, the parent would treat a child app as done as soon as it was created, and the waves would not really wait. You restore it with a custom health check for `argoproj.io/Application` in `argocd-cm`. The lab sets it in `bootstrap/argocd-values.yaml`.

**What do `prune`, `selfHeal`, and `ServerSideApply` do?**
`prune` deletes resources removed from Git. `selfHeal` reverts manual changes to the cluster. `ServerSideApply` avoids the client-side `last-applied` annotation size limit, which kube-prometheus-stack's large CRDs exceed.

**An app is permanently OutOfSync. What do you check?**
`argocd app diff`. Usual causes are controllers mutating fields (CA bundles, replicas under an HPA, defaulted fields). Fix with `ignoreDifferences`, plus `RespectIgnoreDifferences=true` so syncs don't revert them.

**How do you roll back?**
`git revert` and let Argo sync. `argocd app rollback` works only with auto-sync off, and it leaves Git and the cluster disagreeing, so it's an emergency tool.

**What are Argo CD hooks and when do you use them?**
Jobs (or other resources) annotated with `argocd.argoproj.io/hook` to run at a sync phase: `PreSync` (migrations), `PostSync` (smoke tests, notifications), `SyncFail` (alerts), plus `Sync` and `Skip`. A failing PreSync blocks the sync, so the old version keeps serving. Delete policies (`HookSucceeded`, `HookFailed`, `BeforeHookCreation`) control cleanup; I use `BeforeHookCreation` so the last run's logs stay available.

**What happens to Helm hooks under Argo CD?**
Argo renders charts with `helm template`, so there is no Helm release. It maps `pre-install`/`pre-upgrade` to `PreSync` and `post-install`/`post-upgrade` to `PostSync`, which means they run on every sync, since Argo can't tell install from upgrade. `helm.sh/hook-weight` is treated as a sync wave. `helm test` and rollback hooks are not run. For Argo-managed charts, write native Argo hooks. (Newer Argo CD versions also add a `PostDelete` hook for cleanup when an app is deleted.)

**Hooks vs sync waves?**
Waves order resources inside a phase. Hooks add phases around the main sync. Use a PreSync hook for "must finish before anything changes" (a migration) and waves for "A must be healthy before B" (CRDs before custom resources).

**How would you do multiple environments?**
Separate values files or overlays per environment (dev, staging, prod) in Git, one Application (or ApplicationSet element) each, with promotion done by a PR that changes the image tag or chart version. Use AppProjects to restrict which repos, clusters, and namespaces each team can deploy to.

**How does Argo CD authenticate to a private repo, and how do you secure it?**
Repo credentials (deploy key, GitHub App, or token) stored as Secrets in the `argocd` namespace. Prefer a GitHub App or read-only deploy key, SSO with RBAC for users, and disable the default admin after bootstrap.

## Helm
**What is in a chart and what does `_helpers.tpl` do?**
Chart.yaml, values.yaml, and templates. `_helpers.tpl` holds named templates (name, fullname, labels) reused across manifests, so naming and labels are consistent.

**Why are selector labels separate from common labels?**
A Deployment's `spec.selector` is immutable. If you put a changing label (chart version, appVersion) in it, the next upgrade fails. Selector labels stay stable; metadata labels can change.

**`helm template` vs `helm install`?**
`template` renders manifests locally with no cluster contact. It is what CI validates and what Argo CD actually runs: Argo renders the chart itself and applies the output, so Helm release history and `helm rollback` are not used. A related gotcha: the `lookup` template function returns nothing under `helm template`, so charts that use it (for example to keep a randomly generated password across upgrades) behave differently under Argo CD and regenerate the value on every render.

**How do you debug a template?**
`helm lint`, `helm template --debug`, `helm install --dry-run`. Check `toYaml | nindent` indentation first; it is the most common failure.

**Helm vs Kustomize?**
Helm templates and packages with values and has a chart ecosystem. Kustomize patches plain YAML with overlays and no templating. Often combined: Helm for third-party charts, Kustomize for per-environment tweaks.

**How do you upgrade a third-party chart safely?**
Pin the version, read the changelog, render old and new and diff them (`helm template` or `helm diff`), test in a non-prod cluster, then bump the pin in a PR. CRDs need special care because Helm does not upgrade the `crds/` directory.

## External Secrets Operator
**Why ESO over Sealed Secrets or SOPS?**
With ESO the source of truth stays in the secret manager: central rotation, access policy, and audit logs, and nothing encrypted sits in Git. Sealed Secrets and SOPS keep encrypted blobs in Git, which works but ties rotation to commits and key management in the cluster. Trade-off: ESO adds a runtime dependency on the backend being reachable.

**How does it work?**
A `SecretStore` or `ClusterSecretStore` defines the backend and auth. An `ExternalSecret` says which remote keys to fetch and what Kubernetes Secret to create. The controller reconciles on `refreshInterval` and updates the Secret.

**SecretStore vs ClusterSecretStore?**
`SecretStore` is namespaced; `ClusterSecretStore` can be referenced from any namespace (restrict with `namespaceSelector` conditions). Use cluster-scoped for shared platform backends, namespaced when teams own their own credentials.

**A secret rotated. Do the pods pick it up?**
ESO updates the Secret on the next refresh. Env vars are fixed at pod start, so pods need a restart. Mounted Secret volumes update eventually, typically within a minute or two, but not when mounted with `subPath`, and the app still has to re-read the file. I use Reloader, which watches the Secret and triggers a rolling restart.

**How does ESO authenticate to the backend?**
Best: workload identity (IRSA or EKS Pod Identity on AWS), so no static keys exist. Fallback: a bootstrap credential in a Secret, which you then have to protect. 

**What are the risks?**
Anyone who can create an ExternalSecret against a ClusterSecretStore can read whatever that backend identity can read. Scope the IAM role tightly, restrict store usage by namespace, and limit who can create ExternalSecrets with RBAC or policy (Kyverno/OPA).

## Kyverno (policy as code)
The answers in this section are longer on purpose. Learn the first two sentences of each as your spoken answer, and keep the rest for follow-up questions. Everything here is deployed in the lab (`platform/kyverno-policies/`), so point to real files.

**What is Kyverno and where does it sit in the request path?**
Kyverno is a Kubernetes policy engine that runs as a dynamic admission controller. When someone (a person, Argo CD, a controller) sends a create or update to the API server, the request goes through authentication, authorization, the mutating admission stage (built-in plugins such as LimitRanger, then mutating webhooks), schema validation, the validating admission stage (validating webhooks, then built-in checks such as ResourceQuota), and only then is it stored in etcd. Kyverno registers webhooks for both stages, so it can patch an object, reject it, or verify its image signatures.
It also runs controllers outside the request path:
- **Background controller:** generates resources and mutates existing ones.
- **Reports controller:** scans existing resources and writes `PolicyReport`s.
- **Cleanup controller:** deletes resources on a schedule.
Policies are Kubernetes resources, so they live in Git, go through PR review, and Argo CD deploys them like any other manifest. In the lab they are an Argo CD app in wave -1, after Kyverno itself in wave -3.

**Kyverno's policy API changed recently. What do you write today?**
This is a strong point to raise yourself, because it shows you're current.
- Kyverno's original policy kinds were `ClusterPolicy` and `Policy` (`kyverno.io/v1`), with rules written as YAML patterns and JMESPath.
- Kyverno now has **CEL-based policy types** in `policies.kyverno.io`, one kind per job:
  - `ValidatingPolicy`
  - `MutatingPolicy`
  - `GeneratingPolicy`
  - `ImageValidatingPolicy`
  - `DeletingPolicy`
  - Namespaced variants of each, plus a new `PolicyException`.
- Timeline:
  - The CEL types reached v1 in Kyverno 1.17.
  - `ClusterPolicy` was deprecated in 1.19.
  - 1.20 blocks *creating or changing* legacy policies; existing ones keep being enforced.
  - Removal is planned for 1.21.
- Why the change: CEL is the same language Kubernetes uses for its built-in ValidatingAdmissionPolicy and MutatingAdmissionPolicy. One language now covers native and Kyverno policies, and Kyverno can even generate a native ValidatingAdmissionPolicy from a ValidatingPolicy so that simple checks run inside the API server.
- What it means in practice:
  - Don't copy old `ClusterPolicy` examples into a new repo.
  - Teams with existing policies need a migration plan before upgrading. The Helm chart blocks upgrades while legacy policies exist, unless you explicitly acknowledge that they won't be enforced.
  - The lab uses only the CEL types for exactly this reason.

**What kinds of policies are there, and what does each do?**
- **ValidatingPolicy:** allow, deny or audit a resource, for example "every container needs requests and a memory limit" (`require-requests-limits.yaml` in the lab).
- **MutatingPolicy:** patch a resource on the way in, for example add a default label or an `imagePullSecret`.
- **GeneratingPolicy:** create resources when another appears. In the lab, every new tenant namespace gets a ResourceQuota and a LimitRange (`generate/namespace-guardrails.yaml`).
- **ImageValidatingPolicy:** check cosign or Notary signatures and attestations (SBOM, SLSA provenance) before a Pod runs.
- **DeletingPolicy:** delete matching resources on a schedule, for example finished Jobs or expired preview environments.

Matching uses `matchConstraints` (the same structure as native admission policies: API groups, versions, resources, operations, plus namespace and object selectors) and CEL `matchConditions`. The checks are CEL expressions over `object`, `oldObject` and `request`. Each validating policy sets `validationActions`: `Deny`, `Audit` or `Warn`.

The lab's image-tag policy, which is a good one to explain line by line:
```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationActions: [Audit] # Deny once nothing violates it
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchConditions:
    - name: skip-platform-namespaces
      expression: "!(request.namespace in ['kube-system', 'kyverno', 'argocd', 'monitoring'])" # shortened
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.contains('@') ||
          (c.image.matches('^.+:[^/:]+$') && !c.image.endsWith(':latest')))
      message: "Pin every image to a version tag or digest; untagged and ':latest' images are not allowed."
```
Two gotchas worth saying out loud:
- An image with **no tag** (`nginx`) means `latest`, so checking only for `:latest` misses it.
- A **registry port** (`myregistry:5000/app`) contains a colon but isn't a tag. That's why the regex requires a tag after the last slash.
The lab's `tests/kyverno/` has a test case for each of these.

**Audit vs Deny: how do you roll a policy out without breaking teams?**
- **Audit** lets the request through and records the violation in a `PolicyReport`. **Deny** rejects the request with your message. **Warn** returns a warning to the client, which `kubectl` prints.
- The rollout I'd describe:
  1. Ship the policy as Audit through Git and Argo CD.
  2. Background evaluation (on by default) scans existing resources too. Review the results with `kubectl get policyreport -A` or the Policy Reporter UI.
  3. Fix violations in the teams' Git repos.
  4. Grant `PolicyException`s for the justified cases.
  5. Switch the policy to Deny.
- The lab shows both modes side by side. `disallow-latest-tag` is Audit because the chart's image tag is `latest` until CI's first run: the Deployment is admitted, and its PolicyReport shows the failure. The resource and security policies are Deny.
- Run the same policies in CI so teams see failures in their PR before the cluster ever rejects anything.
- Deny only applies at admission. Resources that already violate a policy keep running until they are next updated. Background scanning reports them but doesn't delete them.

**What is auto-gen and why does it matter?**
- You write checks against `Pod`, but people deploy Deployments, StatefulSets, DaemonSets, Jobs and CronJobs.
- When a policy matches only Pods (one resource rule on core `v1` `pods`), Kyverno automatically generates the same check for those pod controllers. It rewrites `object.spec` to the pod template path, and you can see the generated variants in the policy's `status.autogen`. `spec.autogen.podControllers.controllers` narrows the list.
- Why it matters:
  - Without auto-gen, the API server would accept a bad Deployment. The ReplicaSet controller's attempts to create pods would then be denied, and the failure would be visible only in ReplicaSet events while the rollout silently stalls.
  - With auto-gen, the Deployment itself is rejected, so `kubectl apply` or the Argo CD sync fails immediately with the policy's message.
- **Admission-order gotcha the lab demonstrates:** built-in mutating plugins run *before* Kyverno's webhooks. In a namespace with a LimitRange, a bare Pod with no memory limit gets the default filled in first, so a "require memory limits" check passes for the Pod. A Deployment isn't defaulted, because LimitRanger only touches Pods, so auto-gen still catches it.

**Why does the lab exempt platform namespaces instead of opting tenant namespaces in?**
Secure by default. Every policy skips a short, explicit list of platform namespaces (`kube-system`, `kyverno`, `argocd`, `monitoring`, and so on) with a CEL `matchCondition`, and applies everywhere else. A team that creates a new namespace is covered automatically. With opt-in labels, a forgotten label means no policy at all. Exempting Kyverno's own namespace and `kube-system` also means a Kyverno outage can't block its own recovery.

**How do mutating policies interact with GitOps and Argo CD?**
- If Kyverno mutates a resource that Argo CD manages, the live object no longer matches Git. Argo shows the app OutOfSync, and with `selfHeal` it reapplies the Git version, which Kyverno then mutates again. The result is constant noise or a fight between the two.
- Ways to handle it:
  1. **Prefer validation over mutation** for anything a team should fix in their manifests, so Git stays the source of truth. This is why the lab has no mutating policies.
  2. **Mutate objects Argo doesn't track.** Argo tracks the Deployment, not its Pods, so mutating Pods causes no drift.
  3. **Use `ignoreDifferences`**, or Argo CD's server-side diff, for fields you mutate on purpose.
- Good uses of mutation: platform defaults teams shouldn't have to care about (`imagePullSecrets`, a standard label, a default seccomp profile on Pods) and digest pinning in image verification.
- The same problem affects the policies themselves: Kyverno fills in defaults on policies at admission. That's why the lab's policies app uses `ServerSideDiff=true`, which compares against a server-side dry run that includes those defaults.

**How does the lab's GeneratingPolicy work, and what are the gotchas?**
- It matches Namespace creation (skipping platform namespaces) and calls `generator.apply(<namespace>, [quota, limitRange])` with the resources built as CEL objects.
- `evaluation.synchronize.enabled` keeps them matching the policy and recreates them if someone deletes them; README drill 4 shows this.
- `evaluation.generateExisting.enabled` also covers namespaces that existed before the policy.
- **RBAC gotcha:** Kyverno's background controller can only create what it has permission for, and Kyverno rejects a generating policy otherwise. You grant permissions with a ClusterRole carrying the `rbac.kyverno.io/aggregate-to-background-controller: "true"` label (`platform/kyverno-policies/rbac.yaml`). Kubernetes merges it into the controller's role. The aggregation is asynchronous, so the policies app has a sync retry.
- **Argo CD gotchas:**
  - Aggregated ClusterRoles have their `rules` filled in at runtime, so the Kyverno app ignores diffs on ClusterRole rules, as the Kyverno chart's README recommends.
  - If a generated resource is *cloned* from a source that carries Argo CD's tracking label, the clone looks like part of an Argo app and can show up as extra or get pruned. Annotation-based tracking, the default in Argo CD 3.x, avoids this.
- **Why quota and limits per namespace:** it's the Kubernetes version of giving each customer dedicated capacity. One team's runaway Deployment can't starve everyone else.

**How does Kyverno help with supply-chain security?**
- An `ImageValidatingPolicy` checks signatures (and optionally attestations) before a Pod is admitted.
- With **keyless signing**, the GitHub Actions job signs the image with its OIDC identity. Sigstore's Fulcio issues a short-lived certificate for that identity, and the signature is recorded in the Rekor transparency log. There's no signing key to store or rotate.
- The policy pins *who* may have signed (not deployed in the lab; it needs the CI signing step first):
```yaml
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: require-signed-images
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "ghcr.io/YOUR_GITHUB_USER/*"
  validationConfigurations:
    mutateDigest: true # rewrite the tag to the verified digest
  attestors:
    - name: ci
      cosign:
        keyless:
          identities:
            - issuer: https://token.actions.githubusercontent.com
              subject: https://github.com/YOUR_GITHUB_USER/gitops-lab/.github/workflows/ci.yaml@refs/heads/main
        ctlog:
          url: https://rekor.sigstore.dev
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.ci])).all(e, e > 0)
      message: "Images must be signed by the gitops-lab CI workflow on main."
```
- Talking points:
  - `mutateDigest` closes the gap where a tag is re-pushed after verification, because the Pod runs the exact digest that was checked.
  - Pinning the `subject` to the workflow on `main` rejects images built from a fork or a feature branch, even though they are validly signed.
  - The CI side needs one extra step, `cosign sign` with `id-token: write` permission, which reuses the same OIDC mechanism the AWS example uses.

**How do you test policies, and where do they run in CI?**
The lab's CI does both of these on every PR:
- **The policies against the rendered chart:**
  - Run `helm template demo-app charts/demo-app`, stamp the target namespace with `yq` (the policies skip platform namespaces by name), then run `kyverno apply platform/kyverno-policies/policies/ --resource rendered.yaml --audit-warn`.
  - A Deny violation fails the build; `--audit-warn` turns Audit failures into warnings.
  - Developers get the same answer the cluster would give, minutes after pushing instead of at sync time.
- **Unit tests for the policies themselves:**
  - `kyverno test tests/kyverno/` reads a `kyverno-test.yaml` that lists sample resources and the expected `pass` or `fail` result for each policy. The lab's tests cover untagged images, registry ports, digests and the ESO store rule.
  - Policy changes go through PRs with tests like any other code.
- During a migration, the CLI's `--warnings-as-errors` flag can fail the pipeline on deprecation warnings, which stops new legacy policies from sneaking in.

**How do exceptions work without turning into a free-for-all?**
- A `PolicyException` (`policies.kyverno.io/v1`) references policies through `policyRefs` and selects the exempt resources with CEL `matchConditions`, for example `object.metadata.name.startsWith('legacy-agent')`.
- To keep it controlled:
  - Configure Kyverno so exceptions are honored only in one dedicated namespace that application teams can't write to.
  - Require exceptions to arrive through a PR to the platform repo, with an owner and an expiry date in the annotations.
  - Review them periodically.
- This is the policy-as-code equivalent of a change-advisory exception with a paper trail. README drill 6 has you write one.

**Kyverno vs OPA Gatekeeper vs ValidatingAdmissionPolicy vs Pod Security Admission?**
- **Pod Security Admission (built in):** namespace labels choose `privileged`, `baseline` or `restricted`, in `enforce`, `audit` or `warn` mode. It is free and simple but coarse: no custom rules, no custom messages, no per-workload exceptions.
- **ValidatingAdmissionPolicy (built in, GA since Kubernetes 1.30):** CEL expressions evaluated inside the API server, so there is no webhook to keep available and no extra latency. It validates only. Mutation is arriving separately as MutatingAdmissionPolicy in newer Kubernetes releases. There is no generation, image verification or reporting.
- **OPA Gatekeeper:** policies in Rego (`ConstraintTemplate` plus `Constraint`), with an audit function and limited mutation. Rego is powerful and reusable outside Kubernetes (for example with conftest on Terraform), but harder for most teams to learn and review.
- **Kyverno:** now uses the same CEL as the built-in policies, and adds generation, image verification, cleanup, policy reports, exceptions and a CLI for testing. It can also generate native ValidatingAdmissionPolicies. It works only for Kubernetes.
- **My answer:** PSA as a baseline floor, Kyverno for everything that needs custom messages, exceptions, generation, image verification or CI testing. With CEL on both sides, moving a simple check between Kyverno and a native policy is cheap. Gatekeeper is a good choice if the organization already standardizes on OPA/Rego elsewhere.

**What are the operational risks, and how do you run Kyverno in production?**
Kyverno is in the write path of the API server, so it can break the cluster.
- **Failure policy:**
  - With `failurePolicy: Fail`, every matching request is rejected while Kyverno is unavailable.
  - With `Ignore`, requests pass unchecked during the outage, which is a security gap.
  - The CEL policy types set this per policy: Fail for security-critical rules, Ignore for best-practice ones. README drill 8 has you take Kyverno down and watch it.
- **Mitigations:**
  - Run at least 3 admission-controller replicas, with a PodDisruptionBudget, anti-affinity and proper resource requests. The lab runs 1, which is fine on a laptop only.
  - Keep `kube-system` and Kyverno's own namespace out of scope.
  - Keep webhook timeouts low (`webhookConfiguration.timeoutSeconds`).
  - Avoid expensive checks, such as API lookups on every admission request, on high-volume kinds.
- **Monitor:**
  - Admission latency and rejections from Kyverno's Prometheus metrics (for example `kyverno_admission_review_duration_seconds` and `kyverno_policy_results_total`).
  - The API server's `apiserver_admission_webhook_admission_duration_seconds`.
- Kyverno manages its own webhook configurations and registers only for the kinds your policies use, so a narrow set of policies also means a smaller blast radius.

**How did you deploy Kyverno with Argo CD in the lab?**
- `apps/05-kyverno.yaml`: the `kyverno` Helm chart in wave -3, before everything else, so policies exist before the workloads they guard. It uses `ServerSideApply=true` (the CRDs are too large for client-side apply) and ignores diffs on ClusterRole `rules` because of RBAC aggregation.
- `apps/15-kyverno-policies.yaml`: the policies as a separate app in wave -1. That is after ESO (wave -2), because one policy matches ESO's `ExternalSecret` CRD. Inside the app, the RBAC syncs before the policies (wave 0, then 1). It uses `ServerSideDiff=true` for defaulted fields and a retry for the RBAC aggregation race.
- In a bigger cluster, also exclude Kyverno's high-churn report resources from Argo CD's resource tracking, as Kyverno's documentation recommends, to keep load off Argo's application controller.
- When a policy blocks a sync, Argo shows the webhook's denial message in the sync result. That message is what you read first.

**How would you use Kyverno together with ESO?**
- The ESO risk is that anyone who can create an `ExternalSecret` against a shared `ClusterSecretStore` can read whatever that store's identity can read.
- The lab's `restrict-clustersecretstore.yaml` only lets approved namespaces reference a ClusterSecretStore. Every other namespace must use its own namespaced `SecretStore`:
```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: restrict-clustersecretstore
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups: ["external-secrets.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["externalsecrets"]
  matchConditions:
    - name: skip-approved-namespaces
      expression: "!(request.namespace in ['monitoring', 'demo'])" # plus the platform namespaces
  validations:
    - expression: >-
        !has(object.spec.secretStoreRef) ||
        !has(object.spec.secretStoreRef.kind) ||
        object.spec.secretStoreRef.kind == 'SecretStore'
      message: "Use a namespaced SecretStore; ClusterSecretStores are reserved for approved namespaces."
```
- The `has()` checks matter: `kind` is optional and defaults to `SecretStore`, so a manifest that omits it must pass. The unit test `es-default-kind` covers this.
- Pair the policy with the ClusterSecretStore's own `conditions` (namespace selectors) for defense in depth.

## GitHub Actions
**Why not deploy from GitHub Actions?**
It would need cluster credentials stored in CI and gives up drift detection. Actions builds and validates; the commit to Git is the deployment trigger.

**How does the pipeline avoid an infinite loop when it commits the tag bump?**
Pushes made with `GITHUB_TOKEN` don't trigger new workflow runs, and I also put `[skip ci]` in the message and guard the job with an `if`.

**What is OIDC and why use it?**
The job requests a short-lived token from GitHub; the cloud provider exchanges it for temporary credentials if the role's trust policy matches the token's claims (repo, branch, environment). No long-lived keys are stored as secrets. The key detail is restricting the `sub` claim, otherwise any repo could assume the role.

**How do you secure the pipeline itself?**
Least-privilege `permissions:` per job, pin third-party actions to a commit SHA for sensitive pipelines, protect `main` with required reviews and checks, use environments for approvals, scan images (Trivy) and dependencies, and sign images (cosign) if the org requires it.

**How do you speed up builds?**
Layer caching (`cache-from: type=gha`), path filters, concurrency groups that cancel superseded runs, and reusable workflows for shared steps.

## KEDA
**KEDA vs HPA?**
KEDA is event-driven: it supports many scalers (Prometheus, queues, cron, etc.) and scale-to-zero. Under the hood it creates and manages an HPA for 1 to N, and itself handles 0 to 1.

**How does the Prometheus trigger compute replicas?**
It runs your query on `pollingInterval`; with the default AverageValue semantics, desired replicas is roughly `ceil(result / threshold)`, bounded by min and max. In the lab, total request rate divided by 20.

**What stops it from flapping?**
`cooldownPeriod` only governs the final step from 1 to 0. Scaling down from N to 1 is handled by the HPA, whose default scale-down stabilization window is 5 minutes. You tune it through `advanced.horizontalPodAutoscalerConfig.behavior` on the ScaledObject. Choosing a smoothed query (`rate` over 1m or more) also helps. In the lab, with `minReplicaCount: 1`, expect about 5 minutes to scale back down, not the 60s `cooldownPeriod`.

**Why did you add `ignoreDifferences` for replicas?**
KEDA's HPA owns the replica count. Without it, Argo CD sees drift against the Deployment spec and fights the autoscaler.

## Prometheus and Grafana on Kubernetes
Like the Kyverno section, these answers are long on purpose: lead with the first two sentences, keep the rest for follow-ups. Everything here is deployed in the lab, so tie each answer to something you can show: the `PrometheusRule`, the dashboard, or an alert drill.

**What does kube-prometheus-stack install, and how do the pieces fit together?**
It is one Helm chart that installs a complete monitoring stack:
- **Prometheus Operator:** watches custom resources and turns them into Prometheus and Alertmanager configuration, so nobody hand-edits `prometheus.yml`.
- **Prometheus:** scrapes metrics, stores them in its local time-series database (TSDB), and evaluates recording and alerting rules.
- **Alertmanager:** receives firing alerts from Prometheus, then groups, deduplicates, routes and silences them, and sends notifications.
- **Grafana:** dashboards, with Prometheus preconfigured as a data source.
- **kube-state-metrics:** turns Kubernetes object state into metrics.
- **node-exporter:** a DaemonSet that exposes host-level metrics.
- **Defaults:** a set of rules and dashboards (from the kubernetes-mixin project), and ServiceMonitors for the kubelet/cAdvisor, API server, CoreDNS and the stack itself.

The operator's main CRDs:
- `Prometheus`, `Alertmanager` and `PrometheusAgent` describe the servers themselves.
- `ServiceMonitor` and `PodMonitor` say what to scrape. `Probe` does black-box checks through blackbox-exporter, and `ScrapeConfig` covers targets outside the cluster.
- `PrometheusRule` holds recording and alerting rules.
- `AlertmanagerConfig` lets a team define routing for its own namespace.

In the lab, the demo chart ships a ServiceMonitor, a PrometheusRule and a dashboard ConfigMap next to the Deployment, so an app's monitoring is versioned and deployed with the app.

**Where do Kubernetes metrics actually come from?**
This is a favorite question, because people mix the sources up.
- **cAdvisor (built into the kubelet):** container resource *usage*: CPU, memory, network and filesystem. Example metrics: `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`.
- **kube-state-metrics:** the *state* of API objects as Kubernetes sees them. It doesn't measure usage. Examples: desired vs available replicas, pod phase, restart counts, container requests and limits, HPA current vs max (`kube_deployment_status_replicas_available`, `kube_pod_container_status_restarts_total`, `kube_horizontalpodautoscaler_status_current_replicas`).
- **node-exporter:** the host itself: CPU modes, memory, disk, filesystems, network (`node_*`).
- **The kubelet and control plane:** volume stats (`kubelet_volume_stats_*`), API server latency, etcd and scheduler metrics.
- **Your application's `/metrics` endpoint:** business and RED metrics. In the lab: `demo_app_http_requests_total` and the latency histogram.
- **metrics-server is not part of Prometheus.** It keeps only a few minutes of CPU and memory data in memory, serves the `metrics.k8s.io` API, and powers `kubectl top` and CPU/memory-based HPAs.
- **Custom-metric autoscaling** uses either Prometheus Adapter (which serves the custom metrics API) or KEDA, which queries Prometheus directly. The lab uses KEDA.

**How does Prometheus discover and scrape pods?**
- Prometheus *pulls*: every scrape interval it sends an HTTP GET to each target's `/metrics` endpoint.
- On Kubernetes, service discovery watches the API for Endpoints/EndpointSlices, Pods and Nodes, so targets appear and disappear as pods come and go.
- The operator translates a `ServiceMonitor` into that config. It selects Services by label (and namespaces with `namespaceSelector`), then scrapes every endpoint behind them on the named port.
- Each scrape also writes `up` (1 or 0) and `scrape_duration_seconds` for the target. That is a key advantage of pull: Prometheus can tell "the target is down" apart from "the target has nothing to report".
- Push only makes sense in narrow cases: the Pushgateway for short-lived batch jobs that end before a scrape, and remote_write or OpenTelemetry for shipping data elsewhere.
- **relabelings vs metricRelabelings:**
  - `relabelings` run *before* the scrape. They decide which targets to keep and what target labels to attach, for example copying a pod label onto every series.
  - `metricRelabelings` run *after* the scrape on each sample. They drop expensive series or labels before they are stored.

**What are the four metric types, and when do you use each?**
- **Counter:** only goes up, and resets to 0 on restart. Always wrap it in `rate()` or `increase()`, which handle resets. Never graph a raw counter. Example: `demo_app_http_requests_total`.
- **Gauge:** goes up and down, for example memory in use, queue depth or replica count. Graph it directly, or use `avg_over_time` / `max_over_time`.
- **Histogram:** cumulative buckets (`_bucket{le="0.5"}`) plus `_sum` and `_count`. The server computes quantiles with `histogram_quantile`. Histograms can be *aggregated across pods*, which is why they're the right choice for latency in a horizontally scaled service. The quantile is an estimate, so choose buckets around your SLO threshold. In the lab there are buckets at 0.25s and 0.5s because the alert is at 0.5s. Newer Prometheus versions also support native histograms, which don't need fixed buckets.
- **Summary:** quantiles computed in the client. Cheap to query, but you **cannot aggregate them across instances**, because averaging p95s from five pods doesn't give the service's p95. Avoid summaries for anything that scales horizontally.

**What is cardinality, and how do you keep it under control?**
- Every unique combination of metric name and label values is a separate time series. Prometheus memory grows roughly with the number of *active series*, so one bad label can take Prometheus down.
- Dangerous labels have unbounded values: user ID, email, request ID, raw URL path with IDs in it, pod IP, timestamps.
- In the lab app, unknown paths are counted under a single `path="other"` value instead of the raw path. Without that, a vulnerability scanner hitting random URLs would create thousands of series.
- **Find the culprits:** the Prometheus UI's TSDB status page lists the top metrics and labels by series count. Or query `topk(10, count by (__name__) ({__name__=~".+"}))`.
- **Fix it:** fix the instrumentation. Meanwhile, use `metricRelabelings` with `action: drop` or `labeldrop` on the ServiceMonitor. As a safety net, set `sampleLimit` on the ServiceMonitor so one bad target can't take down Prometheus.

**Walk me through the PromQL you'd use day to day on Kubernetes.**
Be ready to write these from memory:
```promql
# Request rate and error ratio (RED). Rate first, then sum. Never sum raw counters, then rate.
sum(rate(demo_app_http_requests_total[5m]))
sum(rate(demo_app_http_requests_total{code=~"5.."}[5m])) / sum(rate(demo_app_http_requests_total[5m]))

# p95 latency across all pods (aggregate the buckets by le, then take the quantile)
histogram_quantile(0.95, sum by (le) (rate(demo_app_http_request_duration_seconds_bucket[5m])))

# CPU per pod in cores; container!="" drops the pod-level cgroup aggregate that would double count
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo", container!=""}[5m]))

# CPU throttling ratio: high values mean the CPU limit is too low, even if average usage looks fine
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{container!=""}[5m]))

# Memory usage vs limit (working set is what the OOM killer acts on; container_memory_usage_bytes includes reclaimable cache)
sum by (pod) (container_memory_working_set_bytes{container!=""})
  / sum by (pod) (kube_pod_container_resource_limits{resource="memory"})

# Restarts and the reason for the last one
increase(kube_pod_container_status_restarts_total[15m]) > 3
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1

# Deployments not at their desired replica count
kube_deployment_spec_replicas != kube_deployment_status_replicas_available

# Disk will fill within 4 hours, based on the last 6 hours of trend
predict_linear(kubelet_volume_stats_available_bytes[6h], 4 * 3600) < 0

# Add the node name to a pod-level metric with a join
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
  * on (namespace, pod) group_left(node) kube_pod_info
```
Points that impress:
- **`rate` vs `irate` vs `increase`:**
  - `rate` is the per-second average over the window, the right choice for alerts and most graphs.
  - `irate` uses only the last two samples. It is spiky, and fine only for zoomed-in debugging graphs.
  - `increase` is `rate` multiplied by the window, giving a count such as "restarts in 15 minutes".
- **Window size:** keep the range at least 4x the scrape interval (`[1m]` or more at a 15s scrape). With too few samples in the window, the result has gaps or jumps around.
- **Rate before sum:** take `rate` first and `sum` afterwards. Summing counters first breaks reset detection when a pod restarts.

**What are recording rules, and why does the lab use them?**
- A recording rule evaluates an expression on a schedule and stores the result as a new series. Expensive queries are computed once instead of on every dashboard refresh and every alert evaluation.
- Naming convention: `level:metric:operations`, for example `namespace_job:demo_app_http_errors:ratio_rate5m`.
- In the lab, the error ratio is recorded over 5m, 30m, 1h and 6h. The burn-rate alerts and the dashboard read those recorded series, so the alert and the graph you look at during an incident always agree.
- Recording rules are also how you build SLO series that stay cheap to query over 30 days.

**What makes a good alert rule?**
Anatomy (see `charts/demo-app/templates/prometheusrule.yaml`):
- `expr`: the condition.
- `for`: how long it must stay true. The alert is *pending* during that time and *firing* after it, which filters out blips.
- `labels`: at least `severity`, used by Alertmanager routing.
- `annotations`: a `summary`, a `description` with the current `$value`, and a **`runbook_url`**. A page at 3 a.m. with no runbook is a bad page. The lab links every alert to `docs/runbooks/demo-app.md`.

Principles:
- Alert on **symptoms users feel** (errors, latency, availability) and use causes for diagnosis. "CPU at 80%" is not a page if users are fine.
- Every page must be actionable and urgent; anything else becomes a ticket or a dashboard.
- Watch for silent failure: an expression over a series that has disappeared returns *nothing*, so it never fires. That's why `DemoAppTargetDown` has an `absent(up{...})` branch for when there are no pods at all.

**Explain SLO burn-rate alerting.**
- The SLI is good requests divided by total requests. The SLO is the target, for example 99.9% over 30 days.
- The error budget is the remaining 0.1%, which is about 43 minutes of total outage per 30 days.
- **Burn rate** is how fast you're using the budget: a burn rate of 1 uses exactly the whole budget over 30 days, and 14.4 uses it in about 2 days.
- The lab uses the multi-window, multi-burn-rate approach from the Google SRE workbook:
  - **Fast burn:** error ratio above 14.4 x 0.1% over **both** 1h and 5m means 2% of the monthly budget is gone in an hour. Page.
  - **Slow burn:** 6x over 6h and 30m means 5% of the budget in 6 hours. Ticket.
- Why two windows: the long window proves the problem is significant, and the short window makes the alert stop quickly once you've fixed it, instead of firing for another hour.
- Why it beats "errors above 1% for 5 minutes": a fixed threshold is noisy at low traffic, ignores how much budget is left, and misses slow leaks entirely.
- Related frameworks to name-drop:
  - **RED** (Rate, Errors, Duration) for services.
  - **USE** (Utilization, Saturation, Errors) for resources such as nodes and disks.
  - Google's **four golden signals** (latency, traffic, errors, saturation).

**How does Alertmanager work?**
Prometheus only decides that an alert is firing; Alertmanager decides who hears about it, how and how often.
- **Routing tree:** matches on labels (`severity`, `team`, `namespace`) to pick a receiver: PagerDuty for critical, Slack for warnings, a "null" receiver for noise.
- **Grouping:** `group_by: [alertname, namespace]` turns 50 pod alerts into one notification. `group_wait` sets how long to wait before the first notification, `group_interval` how often to send updates for a group, and `repeat_interval` how often to re-notify for an unresolved alert.
- **Inhibition:** a critical alert suppresses the matching warning, and "node down" suppresses alerts for every pod on that node.
- **Silences:** time-boxed mutes for planned maintenance, created in the UI or with `amtool`.
- **HA:** run 2 or 3 replicas that gossip with each other. Prometheus sends every alert to all of them, and they deduplicate, so you get one notification.
- **Watchdog:** kube-prometheus-stack ships an always-firing `Watchdog` alert. Route it to an external dead man's switch, a service that pages you when the alert *stops* arriving. That catches "the monitoring itself is down".
- **AlertmanagerConfig CRD:** lets each team own its own routes for its namespace, without editing the global config.

**How do you scale Prometheus and keep data long term?**
- One Prometheus is a single process with a local TSDB. Memory scales with active series, and local retention is typically days to weeks. Give it a PersistentVolume. The lab uses ephemeral storage with 6h retention, so the data is lost when the pod restarts.
- **HA:** run 2 identical replicas scraping the same targets. Alertmanager deduplicates their alerts, and a query layer deduplicates their data.
- **Long-term storage and a global view:**
  - **Thanos:** a sidecar uploads TSDB blocks to object storage (S3/GCS), and a querier merges and deduplicates across clusters.
  - **Grafana Mimir / Cortex:** Prometheus remote-writes into a horizontally scalable backend.
  - **VictoriaMetrics:** a similar remote-write backend.
- **Sharding:** the `shards` field on the `Prometheus` resource splits targets across several Prometheus instances.
- **Agent mode:** `PrometheusAgent` scrapes and forwards with remote_write but stores nothing locally, which is useful for many small clusters reporting to a central backend.
- **Federation** (a central Prometheus scraping aggregated series from others) is an older pattern, now mostly replaced by remote_write.

**How do you manage Grafana properly, not by clicking?**
- **Data sources:** provisioned through Helm values or files, never created by hand.
- **Dashboards as code:**
  - The lab uses the Grafana sidecar, which loads any ConfigMap labelled `grafana_dashboard: "1"` from any namespace. The dashboard JSON lives in the app's chart and ships with the app.
  - Alternatives: the Grafana Operator (`GrafanaDashboard` CRDs), Jsonnet/Grafonnet to generate dashboards, or the Terraform provider.
  - A UI edit to a provisioned dashboard is overwritten on the next sync. Export the JSON and commit it.
- **Portable dashboards:** use a `$datasource` variable instead of a hard-coded data source UID, and variables like `$namespace` so one dashboard serves every environment. The lab dashboard does both.
- **Alerting:**
  - Prefer Prometheus rules in Git for metric alerts: they're evaluated next to the data, reviewed in PRs and highly available through Alertmanager.
  - Use Grafana alerting when an alert needs several data sources, such as Loki logs and metrics together.
- **Access:** SSO through OAuth/OIDC, folder-level permissions, and no shared admin login. In the lab, the admin password comes from the secret store through ESO, not from `values.yaml`.
- **Correlation:** add Loki for logs and Tempo for traces. With *exemplars*, a latency spike on a graph links straight to a trace of a slow request.

**How do you run kube-prometheus-stack itself through Argo CD?**
- **`ServerSideApply=true`:** the CRDs are too big for client-side apply.
- **CRD upgrades:** plain `helm upgrade` never upgrades CRDs, so Helm users must apply new CRDs by hand before upgrading. Argo CD renders with CRDs included and applies them, so under Argo they *are* upgraded with the chart. Read the chart's upgrade notes for major versions either way.
- **The selector gotcha:** by default the stack only selects ServiceMonitors, PodMonitors and PrometheusRules labelled `release: <its release name>`. A team's perfectly valid ServiceMonitor is silently ignored. The lab sets the `*SelectorNilUsesHelmValues: false` flags. In production you'd define a deliberate selector, such as a team label.
- **Turn off what can't be scraped:** on managed clusters (EKS, GKE, AKS) and kind, the scheduler, controller-manager and etcd endpoints aren't reachable. Disable those ServiceMonitors so you don't live with permanent red targets and false alerts. The lab does this.

**How do you monitor the monitoring?**
- The `Watchdog` dead man's switch, from outside the cluster.
- Self-monitoring alerts from the stack: `TargetDown` (a share of a job's targets unreachable), rule evaluation failures (`prometheus_rule_evaluation_failures_total`), Alertmanager notification failures (`alertmanager_notifications_failed_total`), and TSDB growth (`prometheus_tsdb_head_series`).
- If Prometheus can't page you about itself, something outside it has to.

## Scenarios
**Grafana pod is stuck `CreateContainerConfigError`.**
The `grafana-admin` Secret doesn't exist. Check the ExternalSecret status and the store; likely ESO wasn't ready or the key is wrong. This is why the ordering is ESO, then config, then monitoring.

**`ExternalSecret` shows `SecretSyncedError`.**
`kubectl describe externalsecret`: bad remote key, store not Ready, or backend auth/permission failure. Check the ESO controller logs next.

**New image deployed but old pods still running.**
Did CI commit the tag? Did Argo refresh (it polls every ~3 minutes unless a webhook is set up)? Is the sync failing on health? Check `argocd app get`, then pod events (image pull errors from a private GHCR package are common).

**Sync fails on the first run with "no matches for kind".**
The CRD isn't registered yet. Check three things: a wave ordering problem, a missing `SkipDryRunOnMissingResource`, or, in app-of-apps, the missing `Application` health check that stops waves from actually waiting.

**A ServiceMonitor exists, but the target never shows up in Prometheus.**
Work outward from Prometheus's selectors:
1. Does Prometheus select this ServiceMonitor at all? Check the `release` label gotcha (`serviceMonitorSelector`) and `serviceMonitorNamespaceSelector`.
2. Does the ServiceMonitor's `selector` match the *Service's* labels, not the Pod's?
3. Does the endpoint `port` name match a named port on the Service?
4. Does the Service have endpoints (`kubectl get endpointslices`)? If not, the Service selector or readiness is the problem.
5. Does Prometheus have RBAC to list endpoints in that namespace?
Status > Service Discovery in the Prometheus UI shows which targets were discovered and why each was dropped.

**The target shows up but is DOWN.**
Read the error on the Targets page:
- `context deadline exceeded`: a NetworkPolicy is blocking Prometheus, the port is wrong, or the app is too slow to respond.
- `server returned HTTP status 404`: wrong `path`.
- `401` or `403`: the endpoint needs auth or TLS settings in the ServiceMonitor.
- `connection refused`: the app isn't listening on that port or interface.

**Prometheus keeps getting OOMKilled, or its memory climbs every day.**
Almost always cardinality.
1. Open the TSDB status page and find the metric and label with the most series.
2. Usually a deploy just added a high-cardinality label: user ID, raw path, pod IP.
3. Short term: drop the series with `metricRelabelings`, set `sampleLimit`, and raise the memory limit temporarily to recover.
4. Long term: fix the instrumentation, and alert on `prometheus_tsdb_head_series` growth.

**An alert is firing in Prometheus, but nobody was notified.**
1. Check Alertmanager's UI: is it there, silenced or inhibited?
2. Test the routing with `amtool config routes test severity=critical namespace=demo`.
3. Check for receiver errors in `alertmanager_notifications_failed_total` and the Alertmanager logs (bad webhook URL, expired token).
4. Remember `group_wait` delays the first notification.

**You can see the problem on a dashboard, but the alert never fired.**
- The rule may not be loaded. Check Status > Rule health. It could be the `ruleSelector` label gotcha or an evaluation error.
- The expression may return *nothing* instead of false, because of a label mismatch or a disappeared series. Hence `absent()`.
- `for` may keep resetting: if the condition flaps, or the series has scrape gaps, the pending timer starts over.
- The rule's window may differ from the dashboard's. A 5m-rate alert won't see a 30-second spike.

**A pod was OOMKilled, but the dashboard shows memory well below the limit.**
- The spike happened between scrapes. A 15s or 30s scrape interval can miss a sub-second allocation burst.
- You may be graphing the wrong metric. `container_memory_working_set_bytes` is what matters for the limit; RSS or a pod-level average can hide one container's peak.
- Confirm with `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` and `kubectl describe pod`. Then raise the limit or fix the allocation pattern; don't trust the average.

**Grafana panel says "No data".**
- Run the same query in the Prometheus UI. If it's empty there too, the problem is the metric or the labels, not Grafana.
- If it works there, check the panel's data source, the dashboard variables (wrong `$namespace`), the time range, and whether a recording rule has had time to produce data after a fresh deploy.

**A dashboard ConfigMap was deployed, but it never appears in Grafana.**
- Check the label (`grafana_dashboard: "1"`) and the sidecar's `searchNamespace`. By default the sidecar may only watch Grafana's own namespace; the lab sets `ALL`.
- Check the sidecar container's logs in the Grafana pod. Invalid JSON, or a duplicate dashboard `uid`, shows up there.

**KEDA isn't scaling.**
`kubectl describe scaledobject`, check the `Ready`/`Active` conditions, run the query by hand in Prometheus, and check the KEDA operator logs for a connection or empty-result error.

**Every deploy in the cluster fails with "failed calling webhook ... kyverno".**
Kyverno's admission controller is down, overloaded or unreachable, and the webhook `failurePolicy` is `Fail`.
1. Check the Kyverno pods in the `kyverno` namespace: crashloops, OOMKilled, or all replicas on one drained node.
2. Check whether the API server can reach the webhook Service. A NetworkPolicy blocking it is a classic cause.
3. Restore Kyverno first. As a last-resort break-glass step, delete Kyverno's `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` objects (list them with `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep kyverno`). Admission checks stop until Kyverno is healthy and re-registers them, so record it as an incident.
4. Afterwards, add replicas, a PDB and namespace exclusions so it can't happen again.

**Argo CD sync fails with "admission webhook ... denied the request".**
A policy rejected a manifest. Read the policy name and message in the sync result.
- If the policy is right, fix the manifest in Git.
- If there's a valid reason, add a `PolicyException` through a PR.
- Don't disable the policy or switch it to Audit to unblock one app.
- To stop this happening again, run `kyverno apply` against the rendered chart in CI so it fails at PR time.

**A policy is in Enforce, but violating pods are still running.**
Enforcement only happens at admission, so existing resources are untouched until their next update. The background scan lists them in `PolicyReport`s. Remediate them through Git, or for disposable resources use a cleanup policy.

**Argo CD apps went OutOfSync right after a Kyverno policy was added.**
A mutate rule is changing fields on resources Argo CD manages. Change it to validate, target Pods instead of the Deployment, or add `ignoreDifferences` for the mutated field.

## Tie it to your background
Your datacenter work with compliance-driven physical isolation maps directly to the Kubernetes version: namespaces, NetworkPolicies, and per-team AppProjects for logical isolation, with central secret audit and rotation so you can show who accessed what. Kyverno makes that isolation automatic and provable. A generate rule gives every new namespace a default-deny NetworkPolicy and a quota, which is the software version of dedicated switches. Validate rules stop anyone from opting out, and `PolicyReport`s are evidence an auditor can read. Say that out loud: it turns "I used ESO and Kyverno" into "I understand why a regulated environment needs them".

## Questions to ask them
- How do you structure environments and promotions today (repos, branches, ApplicationSets)?
- What is your secret backend, and how is workload identity handled?
- How do you decide what pages someone: SLOs, or threshold alerts?
- Is Prometheus per cluster with a central long-term store (Thanos, Mimir), or something managed? How do teams own their own dashboards and alerts?
- Do you enforce policy at admission (Kyverno, Gatekeeper, built-in ValidatingAdmissionPolicy), and how do teams get exceptions?
- What does on-call look like for the platform team?
