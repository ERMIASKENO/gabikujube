# Developer entry points. CI runs the same targets, so "works on my machine"
# and "works in the pipeline" mean the same thing.
SERVICES := $(notdir $(wildcard apps/*))
ENV ?= dev

.PHONY: help up down test lint validate render tf-plan smoke

help:            ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

up:              ## run the whole shop locally (http://localhost:8080)
	docker compose up --build -d

down:            ## stop local stack
	docker compose down -v

test:            ## unit tests for every service via its Dockerfile test stage
	@for s in $(SERVICES); do echo "== $$s"; docker buildx build --target test apps/$$s || exit 1; done

lint:            ## shellcheck, yamllint, actionlint, bats
	shellcheck $$(git ls-files '*.sh')
	yamllint -c .yamllint.yaml .
	actionlint
	bats scripts/tests

render:          ## regenerate Argo CD cluster manifests from components.yaml
	scripts/ops/render-cluster-apps.sh

validate:        ## helm template + kustomize build + kubeconform everything
	scripts/ci/validate-k8s.sh

tf-plan:         ## terraform plan for ENV (needs az login)
	cd infra/terraform/stacks/platform && \
	terraform init -backend-config=envs/$(ENV).backend.hcl && \
	terraform plan -var-file=envs/$(ENV).tfvars

smoke:           ## smoke test an environment, e.g. make smoke ENV=staging
	scripts/ops/smoke-test.sh --base-url https://$(if $(filter prod,$(ENV)),,$(ENV).)shop.example.com
