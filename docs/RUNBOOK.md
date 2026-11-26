# Runbook

All production changes go through Git. Commands below are for **observing**
and for the few **sanctioned imperative actions** (rollout abort/promote).
Anything else done with kubectl gets reverted by Argo CD self-heal. That's intended.

## Access

```bash
az login
az aks get-credentials -g rg-shopsphere-prod -n aks-shopsphere-prod   # private API: run from the ops VM via Bastion
kubelogin convert-kubeconfig -l azurecli
```

## Releases

| Task | How |
|---|---|
| Watch a rollout | `kubectl argo rollouts get rollout cart -n shop --watch` |
| Abort a canary now | `kubectl argo rollouts abort cart -n shop` (traffic → stable immediately), then revert the digest PR |
| Promote payment (blue-green) | check `RolloutPreview` dashboard + smoke Job, then `kubectl argo rollouts promote payment -n shop` |
| Roll back after promotion | `kubectl argo rollouts undo payment -n shop` within the 10-min scale-down delay (blue still running), then revert in Git |
| Freeze deploys | Argo CD sync windows (Fri 16:00 → Mon 06:00 for `shop`); manual sync still allowed for hotfixes |

## Error budget burn

1. Grafana → *ShopSphere – Golden Signals* → pick the service, then compare `destination_version`.
   If only the new version errors, abort the rollout.
2. Tempo: open an exemplar trace from the error panel and find the failing hop.
3. Loki: `{namespace="shop", app="<svc>"} |= "error" | json`
4. Check dependencies: Service Bus / Redis / PostgreSQL metrics in Azure Monitor, and
   `kubectl get externalsecret -n shop` (secret sync failures).

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `503 UF/URX` at the gateway | all endpoints ejected by outlier detection, or pods not ready | `kubectl get endpoints <svc>-stable -n shop`; check readiness / DestinationRule |
| `403 RBAC: access denied` | caller not in the service's `allowedCallers` | add the caller's SA in `gitops/apps/<svc>/values.yaml` |
| `ImagePullBackOff` + Kyverno event | image unsigned, or not built by `_build-service.yml@main` | promote via the pipeline; never push by hand |
| `AADSTS700213 / 70021` in CI | OIDC subject mismatch (job without the expected `environment:`) | use the environment the federated credential expects |
| Terraform `state blob is already locked` | a cancelled run left a lease | confirm no apply is running, then `terraform force-unlock <id>` from the ops VM |
| Rollout stuck `Paused` with analysis `Inconclusive` | no traffic to the canary | send traffic (smoke test) or extend the pause |
| KEDA not scaling notification | KEDA identity missing Service Bus role / federation | `kubectl describe scaledobject notification -n shop` |

## Secrets

* Rotate DB password: bump `secret_version` in `envs/<env>.tfvars` → PR → apply. ESO
  refreshes within 1 h (or annotate the ExternalSecret `force-sync=$(date +%s)`), then
  Reloader restarts pods.
* Rotate JWT signing key: `scripts/ops/rotate-jwt-key.sh --vault kv-shopsphereprod`.

## Infrastructure

* Drift issue opened by `terraform-drift.yml`: codify the change (see
  `infra/terraform/examples/import-clickops`) or re-apply to revert it.
* Node image / patch upgrades are automatic in the maintenance windows. Minor version
  upgrades: bump `kubernetes_version` in tfvars and go dev → staging → prod.
* Front Door can't reach the origin after a Front Door change: run
  `scripts/ops/approve-frontdoor-pls.sh --node-resource-group rg-shopsphere-prod-nodes`.

## Disaster recovery

* PostgreSQL: point-in-time restore (35 days in prod) to a new server, then switch the
  DSN in Key Vault. Logical dumps via `scripts/linux/backup-postgres.sh` for long-term retention.
* Cluster loss: `terraform apply` + `scripts/bootstrap/bootstrap-cluster.sh`. Argo CD
  rebuilds everything from Git (target: < 1 h). Stateless by design. State lives in PaaS.
