# Interview guide: GitHub Actions, GitHub Enterprise, Azure, Terraform, Kubernetes

This guide turns the ShopSphere repository into answers you can give out loud.
It is organised the way interviews actually run:

1. **The opener**: "Walk me through the most recent workflow you built" (2-minute script)
2. **The whiteboard**: draw the end-to-end pipeline in 5 minutes
3. **Story bank**: 8 STAR stories, including "manual → automated"
4. **The automation framework**: how you approach bringing manual work under automation
5. **Deep-dive Q&A** by topic (Actions, Enterprise, Terraform/Azure, Docker, K8s, Helm/Kustomize, Istio, progressive delivery, GitOps, observability, Linux/Bash)
6. **Scenario curveballs** and **"are you current?"** signals
7. **Questions to ask them** + a command cheat sheet

> **Make it yours.** Interviewers probe until they hit the edge of what you've
> actually done. Deploy the dev environment yourself, break a canary on purpose
> (`SIMULATED_ERROR_RATE=0.3` on payment, `SIMULATED_LATENCY_MS=800` on shipping),
> and replace every `[your number]` with numbers you can defend. One real scar beats
> ten perfect slides.

---

## 1. The opener (≈2 minutes)

**Q: "Tell me about the most recent GitHub Actions workflow you worked on."**

> **Situation.** "We had an e-commerce platform with ten microservices in Go, Node,
> Python and Java, deployed to AKS. Every team had its own pipeline, builds took
> around [40] minutes because everything rebuilt on every change, deploys were
> `kubectl apply` from CI with a long-lived service principal secret, and prod
> releases were all-or-nothing."
>
> **Task.** "I owned redesigning the delivery path end to end: fast and consistent
> CI, secretless access to Azure, a supply chain we could prove, and safe
> progressive releases."
>
> **Action.** "I built one **reusable 'golden path' workflow** that every service
> calls. A **composite action detects which services changed**, so a PR only builds
> what it touched, fanned out as a **matrix**. The contract with teams is the
> Dockerfile: a **multi-stage build with a `test` stage**, so CI is identical for
> every language. Each build is scanned with **Trivy**, gets an **SBOM**, is pushed **by
> digest** to ACR using **OIDC federation** (no secrets), then **signed keylessly with
> cosign** and given a **SLSA provenance attestation**.
>
> "Deployment is **GitOps**: CI never talks to the cluster. A promotion workflow
> verifies the signature, copies the *same digest* to the next environment's
> registry, and changes one line in Git through a **GitHub App** bot: a direct
> commit for dev, a PR that **release managers approve via CODEOWNERS** for prod.
> **Argo CD** syncs it and **Argo Rollouts** runs a **canary** through Istio, checking
> success rate and p95 latency in Prometheus and **rolling back automatically** if
> they degrade. Payment uses **blue-green** with a smoke test and manual promotion.
> When the sync finishes, Argo CD calls back into GitHub, which runs smoke tests and
> records a deployment for our **DORA** metrics."
>
> **Result.** "PR feedback went from [40] to [8] minutes. There are zero long-lived
> cloud secrets in GitHub. Every prod image is traceable to a commit and a
> workflow run. In the first [quarter], canary analysis caught [2] bad releases that
> rolled back before most users saw them."

Have the follow-ups ready: *"Why GitOps instead of deploying from Actions?"*,
*"How does change detection handle shared code?"*, *"What does the OIDC subject look
like?"*, *"How does the cluster know an image is trusted?"* (all answered below).

---

## 2. The whiteboard (5 minutes)

Draw left to right and talk while you draw:

```
 PR ──▶ ci.yml ─────────────────────────────────────────────▶ ci-gate (only required check)
        ├ detect-changes (composite) → matrix[changed services]
        ├ _build-service.yml (reusable) × N
        │     test stage → build → Trivy → SBOM
        │     main only: OIDC→Azure → push digest → cosign sign → attest
        ├ lint (actionlint, shellcheck, yamllint, bats)
        └ platform-validate (helm template × envs → kubeconform)

 merge queue → main ──▶ promote(dev): bot commit digest → gitops/envs/dev
 manual   ──▶ promote(staging|prod): verify sig → oras cp -r → PR → approval

 Git ◀── Argo CD (in cluster, pull) ──▶ Rollout (canary 10/25/50/100)
                                         └ AnalysisRun ⇄ Prometheus (Istio metrics)
 Argo CD Notifications ─repository_dispatch─▶ post-deploy.yml (smoke + Deployment/DORA)

 Infra: terraform.yml  PR: fmt · tflint · test · trivy config · plan×3 (PR comment)
                       main: plan → [approve] → apply saved plan (dev→staging→prod)
        terraform-drift.yml nightly → issue
```

Then draw the runtime: **Front Door (WAF) → Private Link → internal LB → Istio
Gateway → HTTPRoute → services (mTLS) → PaaS over private endpoints**.

---

## 3. Story bank (STAR)

Prepare each as a 60–90 second story. Quote the file you'd show.

### A. Monorepo CI that only builds what changed
* **S/T:** Full rebuild of 10 services per PR; flaky, slow, inconsistent per team.
* **A:** `detect-changes` composite action diffs against the PR base, merge-group
  base or push `before` SHA and outputs a JSON array. If a shared build input changed
  (the reusable workflow, composite actions), it rebuilds everything. A
  `strategy.matrix` fans out `_build-service.yml`. BuildKit `type=gha` cache scoped
  per service. One aggregate **`ci-gate`** job is the only required check, because with
  path filtering, individually required jobs that get skipped would block merges forever.
* **R:** [x]% fewer runner minutes, median PR feedback [y] min.
* *Files:* `.github/actions/detect-changes`, `.github/workflows/ci.yml`.

### B. Secretless CI with OIDC and environment-scoped identities
* **S:** A service principal secret in repo secrets, shared across envs, expired at the
  worst moment, and anyone with write access could exfiltrate it.
* **A:** GitHub OIDC → Entra **federated credentials** on user-assigned managed
  identities. The subject pins `repo:org/repo:environment:<env>`, so only jobs in that
  **GitHub environment** (with its reviewers and branch policy) get the token. Separate
  identities by duty: `ci-publish` (AcrPush), `<env>-plan` (Reader), `<env>` (deploy,
  constrained RBAC admin via an ABAC condition instead of Owner).
* **R:** Zero cloud secrets in GitHub; prod access is impossible from a branch or fork.
* *Files:* `scripts/bootstrap/github-oidc.sh`, `infra/terraform/stacks/github`.

### C. Proving the supply chain
* **S:** Anyone with ACR push could deploy anything; auditors asked "what is running and who built it?"
* **A:** Push by digest; SBOM; BuildKit provenance; `actions/attest-build-provenance`;
  **keyless cosign** inside the reusable workflow, so the certificate identity is
  `.../_build-service.yml@refs/heads/main`. **Kyverno** admits only images signed
  with that identity, rewrites tags to digests, and denies `:latest`. Promotion verifies
  the signature before copying and uses `oras cp -r`, so signatures and attestations
  travel with the image.
* **R:** Every prod pod traces to a commit, a run and an SBOM. Hand-pushed images can't run.

### D. ClickOps → Terraform (the "bring manual things to automation" story)
* **S:** A prod resource group partly created in the portal; nobody knew which NSG rules
  were intentional; DR was a wiki page.
* **A:** Inventory with Resource Graph (`tags.managed_by != "terraform"`). Exported with
  **aztfexport** (`--hcl-only --generate-import-block`) or native **`import` blocks +
  `plan -generate-config-out`**. Iterated until the plan read *N to import, 0 to
  change*. Refactored into modules with **`moved`** blocks; stopped managing legacy bits
  with **`removed { destroy = false }`**. Prevented regression: humans got Reader in
  prod plus PIM break-glass, an Azure Policy deny on untagged resources, and **nightly
  drift detection** that opens an issue.
* **R:** [n] resources adopted with zero downtime; drift issues dropped to ~[0]/month.
* *Files:* `infra/terraform/examples/import-clickops`, `scripts/migrate/import-existing.sh`, `terraform-drift.yml`.

### E. kubectl deploys → GitOps with automated rollback
* **S:** CI ran `kubectl apply` with cluster-admin; rollbacks were "find the old YAML".
* **A:** Argo CD pull model with app-of-apps and ApplicationSets. Desired state per env
  in `gitops/envs/<env>`, so a rollback is `git revert`. Argo Rollouts canary with
  Prometheus analysis on **Istio metrics** (language-agnostic). **`ignoreDifferences`**
  on HTTPRoute weights so Argo CD's self-heal doesn't reset the canary.
* **R:** Change failure rate [x]→[y]%, MTTR [minutes] (rollback is automatic or one revert).

### F. GitHub Enterprise governance as code
* **S:** 100+ repos with hand-clicked branch protection; prod approvals inconsistent.
* **A:** Terraform `integrations/github` manages **rulesets** (signed commits, linear
  history, code-owner review, last-push approval, merge queue, required `ci-gate` +
  CodeQL), **environments** (reviewers, wait timers, branch policies), Actions
  **allow-lists**, variables and teams. Org-level rulesets target repos by **custom
  properties**. The GitOps App is the only bypass actor, and only for dev.
* **R:** Settings reviewed like code; a new repo is compliant on creation.

### G. Linux servers: wiki → idempotent automation
* **S:** "How to build a VM" was 45 manual steps; no two servers were alike.
* **A:** `harden-server.sh` is idempotent (writes only on diff, reloads only what
  changed, `--check` mode for compliance), run by **cloud-init** on first boot. Health
  checks write **node_exporter textfile** metrics atomically, run by a **systemd timer**.
  Backups use managed identity, verify the dump and enforce retention under `flock`.
  The runner install uses an ephemeral JIT registration loop and systemd sandboxing.
  Everything is **shellcheck**-clean and **bats**-tested in CI.
* **R:** Build time from [hours] to [minutes]; same alerting for hosts and pods.

### H. Incident / learning stories (pick one or two)
* **Canary analysis rolled back a bad release.** p95 went from 120 to 900 ms at 10% weight;
  the analysis failed twice, Rollouts aborted, and traffic returned to stable in under 2 min.
  Lesson: analysis must treat *no traffic* (NaN) as inconclusive, not failure.
* **Argo CD vs Rollouts tug-of-war.** Self-heal kept resetting the HTTPRoute weights
  mid-canary. Fixed with `ignoreDifferences` + `RespectIgnoreDifferences=true`.
* **Jobs that never finished.** The Istio sidecar kept migration Jobs alive. Fixed by
  disabling injection for PaaS-only Jobs and enabling **native sidecars** for in-mesh
  analysis Jobs.
* **Promotion PRs with no checks.** PRs created with `GITHUB_TOKEN` don't trigger
  workflows, so required checks never ran. Switched to a **GitHub App** token.

---

## 4. "How do you bring manually configured things to automation?"

Answer with a framework, then an example:

1. **Inventory & observe.** What exists, who changes it, how often. (Resource Graph,
   activity logs, audit logs, `kubectl get -A`, shell history, wiki pages)
2. **Prioritise by risk × frequency.** Things that are changed often or break prod first.
3. **Codify the desired state** in the right tool (table below), **import without
   recreating**, and prove it with a no-op plan or diff.
4. **Make the pipeline the only write path.** Remove human write access, give
   break-glass via PIM, require PR review.
5. **Detect drift continuously.** Nightly plan, Argo CD self-heal, `harden-server.sh --check`.
6. **Measure and socialise.** Lead time, change failure rate, drift count. Write the runbook.

| Manual thing | Automated with | In this repo |
|---|---|---|
| Azure resources clicked in portal | Terraform + import blocks / aztfexport, drift job | `infra/terraform`, `terraform-drift.yml` |
| GitHub branch protection, environments, secrets | Terraform GitHub provider, rulesets | `stacks/github` |
| Service principal secrets | OIDC federated credentials | `github-oidc.sh` |
| kubectl apply / helm upgrade from laptops | Argo CD + Helm/Kustomize in Git | `gitops/` |
| Copying client IDs from portal into YAML | TF outputs → yq → PR | `render-platform-values.sh` |
| Front Door private link approval click | script in pipeline | `approve-frontdoor-pls.sh` |
| Releases & rollbacks | Argo Rollouts + analysis | chart `workload.yaml` |
| Secret rotation | Key Vault + ESO + Reloader, write-only TF attrs | `modules/data`, `rotate-jwt-key.sh` |
| VM build & hardening | cloud-init + idempotent bash | `scripts/linux`, `modules/jumpbox` |
| Dependency updates | Dependabot (grouped, cooldown) | `.github/dependabot.yml` |
| Dashboards & alerts | ConfigMaps / PrometheusRules in Git | chart `prometheusrule.yaml`, `monitoring/` |

---

## 5. Deep-dive Q&A

### 5.1 GitHub Actions

**Reusable workflow vs composite action?**
Reusable workflow = whole **jobs** (own runners, environments, permissions, secrets),
called with `uses:` at job level (nesting depth is limited, so keep it shallow). Composite action = a bundle of
**steps** inside the caller's job. Use reusable workflows for pipeline standards
(build, deploy), composite actions for small shared step sequences (detect changes,
install tools).

**How do you stop workflows having too much power?**
`permissions: contents: read` at top level, elevate per job (`id-token: write` only
where OIDC is needed). Pin actions to **full commit SHAs** (tags are mutable; see
tj-actions/changed-files, 2025). Use an org allow-list, `persist-credentials: false`,
`timeout-minutes` everywhere, and environments for anything that deploys.

**Script injection?**
Never interpolate `${{ github.event.* }}` (PR titles, branch names) directly into `run:`.
Pass it through `env:` and quote it. actionlint and **CodeQL for Actions** catch this.
Avoid `pull_request_target` with a checkout of PR code. If you must use it, never run
the PR's code with secrets.

**How does OIDC work?**
The job requests a JWT from GitHub (needs `id-token: write`). Claims include `repo`,
`ref`, `environment`, `job_workflow_ref`. Azure trusts issuer
`token.actions.githubusercontent.com` with an exact **subject** match
(`repo:org/repo:environment:prod`) and exchanges it for an Entra token. No secret is
stored anywhere. You can customise the subject template to include e.g. `job_workflow_ref`.

**GITHUB_TOKEN vs GitHub App vs PAT?**
`GITHUB_TOKEN` is per-run, scoped and auto-expires, but events it creates don't trigger
new workflows. A GitHub App gives short-lived installation tokens, fine-grained
permissions, can be a ruleset bypass actor, and isn't tied to a person. PATs are tied to a
human; avoid them (or use fine-grained ones with expiry).

**Cache vs artifacts?**
Cache = speed (dependencies, BuildKit layers). It's best-effort and evicted.
Artifacts = outputs you need later (SBOM, plan file, digests), retained for N days.
Getting matrix job outputs: each leg uploads a small artifact, and the consumer downloads
with `pattern` + `merge-multiple` (matrix outputs overwrite each other).

**Environments?**
Required reviewers, wait timers, deployment branch policies, env-scoped
secrets/variables, custom deployment protection rules (e.g. a ServiceNow change ticket),
and the `environment` OIDC claim. In this repo: `*-plan` (no approval, any branch) vs
`dev/staging/prod` (main only, approvals).

**Why a merge queue?**
It tests the PR *as merged with everything ahead of it*. That avoids "green PR, red main"
when two PRs conflict semantically. Workflows must also trigger on `merge_group`.

**Concurrency?**
`concurrency.group` serialises per env (`tf-apply-prod`, `promote-prod`) with
`cancel-in-progress: false` for deploys/applies, and `true` for PR CI so outdated runs die.

**Self-hosted runners: risks and patterns?**
Never on public repos. Make them **ephemeral** (one job per runner), put them in **runner
groups** restricted to selected repos/workflows, and run them as an unprivileged user.
In-cluster: **ARC runner scale sets** (scale from 0, `containerMode: kubernetes` to avoid
privileged DinD). For private Azure resources without managing VMs: **GitHub-hosted
runners with Azure private networking** (VNet injection, GHEC).

**How do you debug a workflow?**
Re-run with debug logging (`ACTIONS_STEP_DEBUG` / `ACTIONS_RUNNER_DEBUG`), job summaries,
`actionlint` locally, `act` for quick iteration, and tmate only on private self-hosted runners.

**Required checks with path filters?**
A skipped required job leaves the check "expected" forever. Use one always-running gate job
(`if: always()`, assert all `needs` are success/skipped), as `ci-gate` does here.

### 5.2 GitHub Enterprise

* **GHEC vs GHES vs EMU.** GHEC is SaaS. GHES is self-hosted (air-gapped/regulated; you
  run upgrades, HA and backups). **Enterprise Managed Users** = identities provisioned
  from Entra ID via SCIM; users can't create public content and the company owns accounts.
  GHEC also offers data residency.
* **Policy layers.** Enterprise → org → repo. Enterprise policies for Actions (allowed
  actions, SHA pinning requirement, fork PR approval), repo creation and visibility, and
  2FA/SAML. **Rulesets** (repo or org, targetable by **custom properties**) replace classic
  branch protection: layered, with bypass lists and evaluate mode to dry-run a rule.
  Required workflows are enforced via rulesets now.
* **Audit.** Audit log streaming to Event Hubs / Sentinel / Splunk, Git events, and
  token/App usage.
* **GHAS.** Code scanning (CodeQL + third-party SARIF like Trivy), secret scanning with
  **push protection** and custom patterns, Dependabot alerts/updates, dependency review,
  security overview, Copilot Autofix.
* **Identity & access.** SAML SSO / OIDC with CAP (Entra conditional access), IP allow
  lists, teams synced from Entra groups, CODEOWNERS for mandatory reviewers.
* **Runners at scale.** Runner groups per business unit, larger runners (more CPU/GPU,
  static IPs), Azure private networking, ARC on AKS, usage reporting and spending limits.
* **Inner source.** Internal visibility, org-level workflow templates (`.github` repo),
  shared reusable workflows referenced `@<sha>`.

### 5.3 Terraform & Azure

* **State.** Azure Storage with **Entra auth** (`use_azuread_auth`, shared keys disabled),
  blob lease = lock, versioning + soft delete for recovery, one state per env/stack, and a
  resource lock on the RG.
* **Envs.** One root module + per-env tfvars/backend vs directories per env vs workspaces.
  I prefer tfvars + partial backend config (DRY, explicit, separate state). Workspaces share
  a backend config and are easy to confuse.
* **`for_each` vs `count`.** `for_each` with stable keys avoids index shifting. Keys must be
  known at plan time, so pass **maps with static keys** when values are unknown
  (`{ aks_kubelet = module.aks.kubelet_object_id }`).
* **Plan/apply.** Plan on PR (read-only identity, posted as a comment); on main, plan →
  approval → **apply the saved plan** (a stale plan is rejected). Serialise with concurrency.
* **Import / moved / removed / check / test.** Know all five. `terraform test` with
  `mock_provider` runs in CI without cloud credentials.
* **Secrets.** Terraform ≥1.11 **ephemeral resources + write-only attributes**
  (`administrator_password_wo`, `value_wo`) keep secrets out of state. Mark outputs
  `sensitive`. Restrict state access.
* **Providers.** Pin with `~>` and commit `.terraform.lock.hcl`. Use **AzAPI** for brand-new
  services or properties azurerm doesn't have yet (Azure Managed Redis here). azurerm
  5.0 is GA; plan the upgrade deliberately.
* **Guard-rails.** `prevent_destroy`, variable `validation`, tflint, Trivy/Checkov IaC
  scans, Azure Policy, budgets, `check` blocks.
* **AKS design choices to defend.**
  * *Azure CNI Overlay + Cilium:* pods don't consume VNet IPs, eBPF dataplane, network policy built in.
  * *Private API server:* this is why GitOps pull matters; ops access goes through Bastion + jumpbox.
  * *Entra-only auth, local accounts disabled:* no static kubeconfig to leak.
  * *Workload Identity:* the pod's projected SA token is federated to a UAMI. It replaced
    pod-managed identity (deprecated).
  * *NAT Gateway egress:* a stable IP to allow-list, no SNAT exhaustion.
  * *System pool tainted `CriticalAddonsOnly`; zonal apps pool; spot pool for batch.*
  * *Auto-upgrade:* `patch` + `NodeImage` channels in maintenance windows; minor versions
    are promoted dev → prod. AKS supports N-2 GA minors (12 months each), and LTS is available.
* **Front Door + Private Link.** Front Door Premium origin → PLS created by AKS from Service
  annotations → internal LB. The connection must be approved (scripted). WAF in Detection
  first, then Prevention after tuning.
* **Data.** PostgreSQL Flexible with zone-redundant HA, PITR and private VNet integration;
  Azure Managed Redis (Azure Cache for Redis is retiring); Service Bus with
  `local_auth_enabled = false` (Entra only), duplicate detection and DLQ.

### 5.4 Docker / images

* **Multi-stage.** deps (cached on lockfile) → test → build → runtime. Order layers from
  least to most frequently changing; use `--mount=type=cache` for package managers.
* **Runtime.** distroless/static for Go, distroless Node/Java, slim + venv for Python.
  Non-root numeric UID, no shell, read-only root FS.
* **JVM.** `-XX:MaxRAMPercentage` (container-aware heap); Spring Boot layered jars
  (`-Djarmode=tools extract --layers`) so code-only changes push one small layer.
* **Signals.** Exec-form `CMD/ENTRYPOINT` so the app is PID 1 and receives SIGTERM.
  Handle it: fail readiness, drain, exit.
* **Identity.** Deploy by **digest**; tags are for humans. Multi-arch with buildx + QEMU
  (Arm64 nodes are cheaper).
* **Evidence.** SBOM, provenance, signature, vulnerability gate on *fixable* HIGH/CRITICAL.

### 5.5 Kubernetes

* **Probes.** *startup* protects slow boots; *liveness* = "am I wedged?" (never check
  dependencies, or a DB blip restarts everything); *readiness* = "can I take traffic?"
  (may check hard dependencies).
* **Zero-downtime shutdown.** SIGTERM and endpoint removal race. Use a `preStop` sleep
  (native `sleep` action, no shell needed), the app fails readiness and drains, and
  `terminationGracePeriodSeconds` must exceed preStop + drain.
* **Resources.** Requests drive scheduling and HPA; memory limit always; **no CPU limit**
  for latency-sensitive services (CFS throttling). QoS classes: Guaranteed / Burstable / BestEffort.
* **Availability.** PDB (`maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`),
  topologySpreadConstraints across zones and nodes, PriorityClasses (checkout >
  standard > batch, batch with `preemptionPolicy: Never`).
* **Autoscaling.** HPA v2 with `behavior` (fast up, slow down); **KEDA** for event-driven
  scaling and scale to zero; VPA in recommend mode (don't fight HPA on the same metric);
  cluster autoscaler for nodes.
* **Security.** PSA `restricted`, `automountServiceAccountToken: false`, RBAC via Entra
  groups, NetworkPolicy default-deny + allow-lists, ResourceQuota/LimitRange per namespace,
  admission policies (Kyverno or ValidatingAdmissionPolicy).
* **Workload types.** Deployment/Rollout (stateless), StatefulSet (stable identity/storage;
  prefer PaaS for databases), DaemonSet (node agents: Alloy), Job/CronJob
  (`concurrencyPolicy: Forbid`, `activeDeadlineSeconds`, `ttlSecondsAfterFinished`).
* **Gateway API vs Ingress.** Typed, role-oriented (GatewayClass/Gateway/Routes), with
  traffic splitting, header matching, timeouts and cross-namespace delegation. ingress-nginx
  is retired, and Ingress itself is feature-frozen.

### 5.6 Helm vs Kustomize

* **Helm** for packaging something templated and reused many times (our golden-path chart
  for all 10 services, third-party add-ons). Values layering: service → env → env/service.
* **Kustomize** for cluster config that differs slightly per env (JSON6902 patches on plain
  YAML; no templating language).
* **Together:** Argo CD renders Helm with multiple value files (multi-source `$values`
  ref); Kustomize overlays for cluster config.
* **Chart quality:** `values.schema.json`, `helm lint --strict`, `helm template` +
  kubeconform in CI, `helm test` hook, checksum annotation to roll pods on config change,
  and job pods must *not* reuse Service selector labels.

### 5.7 Istio

* **Sidecar vs ambient.** Ambient (ztunnel L4 + optional waypoint L7) cuts per-pod overhead.
  Sidecars give mature per-workload L7. Here: sidecars, native-sidecar mode, istio-cni.
* **mTLS migration.** PERMISSIVE → check telemetry that all traffic is mTLS → STRICT.
* **AuthZ.** Default deny + ALLOW by SPIFFE principal
  (`cluster.local/ns/shop/sa/order`); JWT at the gateway (`RequestAuthentication` + DENY
  when `notRequestPrincipals: ["*"]`).
* **Resilience.** Timeouts, retries (only idempotent, or with idempotency keys), outlier
  detection, connection pools.
* **Egress control.** `outboundTrafficPolicy: REGISTRY_ONLY` + ServiceEntries.
* **Prometheus with STRICT mTLS.** Metrics merging on `:15020` (no plaintext app scrape needed).
* **Troubleshooting.** `istioctl analyze`, `istioctl proxy-config routes|clusters|endpoints <pod>`,
  `istioctl x describe pod`, Envoy response flags (`UF`, `UH`, `NR`, `URX`, `DC`).

### 5.8 Progressive delivery

* **Canary vs blue-green vs rolling vs feature flags.** Canary limits the blast radius by %
  of traffic. Blue-green gives an atomic switch with no mixed versions and instant rollback
  but double capacity. Rolling is cheapest with no traffic control. Feature flags separate
  deploy from release (use them with canaries).
* **What to analyse.** Error rate and p95 latency of the *canary* (not the whole service),
  business KPIs (checkout conversion) for big changes, NaN = inconclusive.
* **Databases.** Expand/contract migrations; PreSync migration Job; never deploy a
  destructive schema change together with code that needs it.
* **Rollback paths.** Automatic abort (analysis), `kubectl argo rollouts abort|undo`,
  `git revert` of the digest bump (source of truth).
* **Cluster-level blue-green.** A new AKS cluster from the same Git, weighted Front Door
  origins, shift traffic, retire the old cluster. Use it for risky minor upgrades or CNI changes.

### 5.9 GitOps / Argo CD

* **Push vs pull.** Pull means CI has no cluster credentials, drift gets corrected
  (self-heal), Git is the audit log, and DR is "re-sync".
* **Structure.** Root app-of-apps → ApplicationSets (git directory generator for services,
  list generator for add-ons). Sync waves and hooks (`PreSync` migrations). Custom health
  for `Application` so app-of-apps waits correctly.
* **Promotion.** Different value files per env in one repo; the CI bot bumps digests.
  The alternative is Argo CD Image Updater; I prefer explicit PRs for prod (review + audit).
* **Secrets.** Never in Git. Use External Secrets (or Sealed Secrets / SOPS). Here: Key Vault + ESO.
* **Guard-rails.** AppProjects (allowed repos/destinations/kinds), sync windows (change
  freeze), RBAC from Entra groups, notifications.
* **Argo CD vs Flux.** Both are CNCF graduated. Argo CD has the UI, ApplicationSets and
  Rollouts ecosystem. Flux is more composable/CLI-native with Flagger.

### 5.10 Observability

* **Signals.** Golden signals / RED for services, USE for resources.
* **SLOs.** SLI (good/total) → SLO (99%) → error budget (1%) → **multi-window burn-rate**
  alerts (14.4× over 5m & 1h → page; slow burn → ticket). Alert on symptoms, not causes.
* **Cardinality.** Never label by user ID, order ID or URL with IDs. Route templates only.
* **Correlation.** Trace context propagation (W3C `traceparent`), trace → logs → metrics in
  Grafana (Tempo `tracesToLogs`, exemplars).
* **Delivery health.** DORA: deployment frequency, lead time, change failure rate, time to restore.

### 5.11 Linux & Bash

* **Strict mode.** `set -euo pipefail` and its traps: `-e` is ignored inside `if`/`&&`, so
  handle return codes on purpose. `local x=$(cmd)` masks failures (declare and assign
  separately). Quote everything. `IFS` matters for loops.
* **Patterns.** `trap` cleanup, `flock` to prevent overlap, atomic writes (tmp + `mv`),
  `retry` with backoff, `--dry-run`/`--check` modes, logs to stderr and data to stdout,
  JSON logs for machines.
* **Idempotency.** Check state before change; write only on diff; reload only what
  changed; re-runnable without side effects.
* **systemd.** Units and timers over cron (logs in journald, dependencies, sandboxing:
  `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`).
* **Troubleshooting.**
  * load: `uptime`, `top`/`htop`, `vmstat 1`, `iostat -x 1`, `pidstat`
  * memory: `free -m`, `dmesg -T | grep -i oom`, `/proc/meminfo`
  * disk: `df -h`, `du -xh --max-depth=1 / | sort -h`, `lsof +L1` (deleted but open)
  * network: `ss -tulpn`, `ip a`, `ip r`, `dig`, `curl -v`, `tcpdump -i any port 443`
  * services: `systemctl status`, `journalctl -u x --since -1h`
* **Hardening.** SSH (no root, no passwords, Entra login), ufw, fail2ban, unattended
  security upgrades, sysctl, auditd rules, persistent bounded journald.
* **Quality.** shellcheck in CI, bats tests, a shared `lib/common.sh`.

---

## 6. Scenario curveballs

| They ask | Your answer in one breath |
|---|---|
| "CI takes 40 minutes." | Measure first (job timing). Change detection, BuildKit cache, parallel matrix, test in the Dockerfile stage, bigger runners only for the hot path, split slow integration tests into the merge queue. |
| "A deploy failed halfway in prod." | With Rollouts it doesn't "half deploy": analysis aborts and traffic goes back to stable. Then: read AnalysisRun, compare versions in Grafana, revert the digest PR, postmortem. |
| "A secret leaked in logs." | Revoke/rotate first (Key Vault + ESO), purge logs, find the cause (masking, `set -x`), add a secret-scanning custom pattern, prefer OIDC so there's nothing to leak. |
| "Someone changed an NSG in the portal." | Nightly drift issue catches it. Decide: codify (import) or revert (apply). Then remove the access that allowed it. |
| "Canary metrics are green but users complain." | The SLI doesn't measure what users feel: add business/client-side metrics, check the canary got real traffic (weights, session affinity), extend the analysis. |
| "Onboard an 11th service." | Add `apps/<svc>` with Dockerfile + test stage, `gitops/apps/<svc>/values.yaml`, env files. The ApplicationSet picks it up and CI builds it automatically. Zero pipeline YAML. |
| "Scale this to 200 repos." | Central reusable workflows referenced by SHA, org rulesets by custom properties, workflow templates, ARC runner groups, Backstage/IDP scaffolding. |
| "Cut cloud cost 30%." | Rightsize requests (VPA recommendations), spot for batch/preview, scale to zero (KEDA), autoscaler limits, reserved instances/savings plans for the baseline, log sampling/retention, budgets. |
| "Roll back a DB migration." | You don't. Migrations are forward-only and backward compatible; roll the code back, and fix forward. |
| "Kyverno is down and blocks all pods." | Webhook HA (3 replicas, PDB), `failurePolicy` choices, exclude system namespaces, alerts on webhook latency, break-glass to delete the webhook config. |
| "Argo CD is down." | The running apps are unaffected (it's a reconciler). Fix Argo, it re-syncs. For hotfixes: break-glass process with audit, then commit to Git. |
| "Why not deploy straight from GitHub Actions?" | You can (environments + OIDC + `helm upgrade`). But pull-based GitOps removes cluster creds from CI, works with private API servers, self-heals drift and makes Git the audit log. |

---

## 7. "Are you current?" (late-2026 signals)

Mention these casually, and only the ones you can explain:

* **ingress-nginx is retired** (maintenance ended March 2026) → **Gateway API**
  (Istio/Envoy Gateway/Cilium). `ingress2gateway` 1.0 exists for migrations.
* **Azure Cache for Redis is retiring** → **Azure Managed Redis** (creation of new caches
  is already blocked). Here it's deployed via AzAPI.
* **AKS:** 1.35–1.37 are the supported GA minors (1.38 in preview); Azure Linux 2.0 node
  images were removed in March 2026 → Azure Linux 3.
* **Terraform:** ephemeral resources + write-only attributes (no secrets in state),
  `terraform test` with mocks; **AzureRM 5.0 is GA**, so plan the upgrade.
* **Helm 4** is out; Istio 1.32; Gateway API 1.7; Argo CD 3.x; Argo Rollouts 1.10.
* **Actions:** `checkout@v7`, Node 24 action runtime, artifact attestations, CodeQL for
  Actions workflows, SHA-pinning enforcement policy, Dependabot `cooldown` (supply-chain
  defence), GitHub-hosted runners with Azure private networking.
* **Observability:** Promtail → **Grafana Alloy**; OpenTelemetry everywhere.

---

## 8. Questions to ask them

* "How many clusters and environments, and is deployment push or pull today?"
* "What's your current lead time and change failure rate, and which one hurts more?"
* "GHEC or GHES? EMU? How are runners provided: hosted, ARC, VMs?"
* "Where is the biggest remaining manual step between merge and production?"
* "How do platform and product teams split ownership of pipelines and manifests?"

---

## 9. Cheat sheet

```bash
# Actions
gh run list -w ci --limit 5;  gh run view <id> --log-failed;  gh workflow run promote.yml -f target=staging
actionlint;  gh attestation verify oci://<acr>/shopsphere/cart@sha256:... --owner shopsphere
cosign verify <img@digest> --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/ERMIASKENO/gabikujube/.github/workflows/_build-service.yml@refs/heads/main

# Terraform
terraform init -backend-config=envs/prod.backend.hcl
terraform plan -var-file=envs/prod.tfvars -out tfplan -detailed-exitcode   # 0 none, 1 error, 2 changes
terraform plan -generate-config-out=generated.tf                           # with import blocks
terraform state list | grep aks;  terraform force-unlock <lock-id>;  terraform test

# AKS / K8s
az aks get-credentials -g rg -n aks && kubelogin convert-kubeconfig -l azurecli
kubectl get pods -n shop -o wide;  kubectl describe pod x;  kubectl logs x -c app --previous
kubectl top pods -n shop;  kubectl get events -n shop --sort-by=.lastTimestamp
kubectl auth can-i --list --as system:serviceaccount:shop:order

# Rollouts / Argo CD
kubectl argo rollouts get rollout cart -n shop -w;  ... promote|abort|undo|retry
argocd app get cart;  argocd app diff cart;  argocd app history cart;  argocd app rollback cart <id>

# Istio
istioctl analyze -n shop;  istioctl proxy-config routes deploy/order -n shop;  istioctl x describe pod <pod>

# Helm / Kustomize
helm template cart deploy/charts/microservice -f gitops/apps/cart/values.yaml -f gitops/envs/prod/apps/cart.yaml
kustomize build gitops/cluster-config/overlays/prod | kubeconform -strict -summary
```
