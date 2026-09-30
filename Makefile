SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.RECIPEPREFIX := >

ENV ?=
CONFIRM_REVOKE ?=
KUBE_CONTEXT ?= kind-kubernetes-gitops-dev

KEY_ROOT := $(HOME)/.config/kubernetes-gitops-platform/keys
KEY_FILE = $(KEY_ROOT)/$(ENV)/argocd-repo

.DEFAULT_GOAL := help

.PHONY: \
  help \
  require-env \
  preflight \
  check \
  key \
  register-key \
  revoke-key \
  key-path \
  cluster \
  argocd \
  repo-auth \
  gitops \
  validate \
  validate-kafka \
  bootstrap

help:
> @echo "Kubernetes GitOps Platform"
> @echo
> @echo "Safe bootstrap workflow:"
> @echo "  make preflight"
> @echo "  make key ENV=<environment>"
> @echo "  make register-key ENV=<environment>"
> @echo "  make revoke-key ENV=<environment> CONFIRM_REVOKE=argocd-repo-<environment>"
> @echo "  make cluster"
> @echo "  make argocd"
> @echo "  make repo-auth ENV=<environment>"
> @echo "  make gitops"
> @echo "  make validate"
> @echo "  make validate-kafka"
> @echo
> @echo "Convenience:"
> @echo "  make check"
> @echo "  make key-path ENV=<environment>"
> @echo "  make bootstrap ENV=<environment>"
> @echo
> @echo "Defaults:"
> @echo "  KUBE_CONTEXT=$(KUBE_CONTEXT)"
> @echo
> @echo "Security:"
> @echo "  - Every environment uses its own SSH deploy key."
> @echo "  - Private keys remain outside the repository."
> @echo "  - register-key only registers public keys."
> @echo "  - repo-auth refuses to replace existing repository credentials."
> @echo "  - bootstrap does NOT generate or register credentials automatically."
> @echo "  - No destructive cluster target is provided."

require-env:
> @if [[ -z "$(ENV)" ]]; then \
>   echo "ERROR: ENV is required"; \
>   echo "Example: make $@ ENV=dev-rebuild"; \
>   exit 1; \
> fi

preflight:
> ./scripts/preflight.sh

check:
> @echo "===== SHELL SCRIPT SYNTAX ====="
> @for file in scripts/*.sh; do \
>   bash -n "$$file"; \
>   echo "PASS: $$file"; \
> done
> @echo
> @echo "===== GIT DIFF CHECK ====="
> git diff --check
> @echo
> @echo "===== PREFLIGHT ====="
> ./scripts/preflight.sh

key: require-env
> ./scripts/generate-repo-deploy-key.sh "$(ENV)"

register-key: require-env
> ./scripts/register-repo-deploy-key.sh "$(ENV)"

key-path: require-env
> @echo "$(KEY_FILE)"

cluster:
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/create-cluster.sh

argocd:
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/bootstrap-argocd.sh

repo-auth: require-env
> @if [[ ! -r "$(KEY_FILE)" ]]; then \
>   echo "ERROR: private deploy key not found:"; \
>   echo "  $(KEY_FILE)"; \
>   echo; \
>   echo "Generate a unique credential first:"; \
>   echo "  make key ENV=$(ENV)"; \
>   exit 1; \
> fi
> ARGO_REPO_SSH_KEY_FILE="$(KEY_FILE)" \
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/configure-repo-auth.sh "$(ENV)"

gitops:
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/bootstrap-gitops.sh

validate:
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/validate-platform.sh

validate-kafka:
> KUBE_CONTEXT="$(KUBE_CONTEXT)" \
>   ./scripts/validate-kafka-mtls.sh

#
# Deliberately excludes key generation and GitHub registration.
# Credential creation/registration must remain explicit actions.
#
bootstrap: require-env
> $(MAKE) preflight
> $(MAKE) cluster KUBE_CONTEXT="$(KUBE_CONTEXT)"
> $(MAKE) argocd KUBE_CONTEXT="$(KUBE_CONTEXT)"
> $(MAKE) repo-auth ENV="$(ENV)" KUBE_CONTEXT="$(KUBE_CONTEXT)"
> $(MAKE) gitops KUBE_CONTEXT="$(KUBE_CONTEXT)"
> $(MAKE) validate KUBE_CONTEXT="$(KUBE_CONTEXT)"
> @echo
> @echo "PASS: reproducible platform bootstrap completed"
> @echo "Run functional Kafka validation separately with:"
> @echo "  make validate-kafka"

# Revoke an environment-specific GitHub deploy key.
# Requires an exact explicit confirmation value.
revoke-key: require-env
> @if [[ "$(CONFIRM_REVOKE)" != "argocd-repo-$(ENV)" ]]; then echo "ERROR: explicit revocation confirmation is required"; echo; echo "Run:"; echo "  make revoke-key ENV=$(ENV) CONFIRM_REVOKE=argocd-repo-$(ENV)"; exit 1; fi
> CONFIRM_REVOKE="$(CONFIRM_REVOKE)" ./scripts/revoke-repo-deploy-key.sh "$(ENV)"
