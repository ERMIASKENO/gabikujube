## What & why
<!-- one or two sentences; link the issue -->

## How it was tested
- [ ] unit tests (Dockerfile `test` stage)
- [ ] `docker compose up` locally / dev environment
- [ ] Terraform plan reviewed (infra changes)

## Rollout & rollback
- Strategy: canary / blue-green / rolling (from gitops values)
- DB migration backward compatible? (expand -> migrate -> contract)
- Rollback: `kubectl argo rollouts abort <svc>` or revert this PR
