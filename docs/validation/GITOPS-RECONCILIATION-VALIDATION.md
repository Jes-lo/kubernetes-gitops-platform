# GitOps Reconciliation Validation

## Date

2026-09-29

## Scope

This validation demonstrates the initial GitOps reconciliation workflow of the
Kubernetes GitOps Platform.

The test environment is a local multi-node Kubernetes cluster created with kind.

The validation is intended to demonstrate GitOps behavior in a portfolio lab
environment. It is not intended to claim production high availability or
production-grade durability.

## Architecture Under Test

The validated flow is:

    Developer
        |
        v
      GitHub
        |
        v
      Argo CD
        |
        v
    Kubernetes

Git is the desired-state source.

Argo CD reads the private GitHub repository through a dedicated read-only SSH
deploy key and continuously reconciles the approved state from the `main`
branch.

## Repository Authentication

The private repository uses a dedicated SSH deploy key.

Validated properties:

- repository-specific credential
- read-only GitHub access
- SSH host verification enabled
- private key stored outside Git
- private key not managed through Terraform
- private key permissions restricted locally
- Argo CD repository Secret stored inside the `argocd` namespace

Direct repository read access was validated with `git ls-remote`.

## Initial Reconciliation Test

Before the GitOps bootstrap:

- namespace `demo-dev` did not exist
- ConfigMap `gitops-proof` did not exist

Only the following bootstrap resources were applied manually:

- Argo CD `AppProject`
- Argo CD `Application`

The Git-managed Namespace and ConfigMap were not applied manually.

Argo CD reconciled the desired state from Git and created:

- Namespace `demo-dev`
- ConfigMap `demo-dev/gitops-proof`

Observed Application state:

    SYNC STATUS:   Synced
    HEALTH STATUS: Healthy

The reconciled Git revision was:

    b72aa174b46c40961b3dce907225d568e9b6c341

The resulting ConfigMap contained:

    managed-by=argocd
    environment=development
    source-of-truth=git

## Drift Detection and Self-Healing Test

The live ConfigMap was intentionally modified directly in Kubernetes:

    source-of-truth=manual-drift

No Git change was made.

Argo CD detected that the Kubernetes live state no longer matched the Git
desired state.

Because automated synchronization and self-healing were enabled, Argo CD
reconciled the resource back to:

    source-of-truth=git

Observed result after reconciliation:

    source-of-truth=git
    sync=Synced
    health=Healthy

The correction occurred without modifying the Git desired state.

The Git working tree remained clean throughout the test.

## Result

The test validated:

- private Git repository access
- Git as the desired-state source
- automated reconciliation
- Kubernetes resource creation through Argo CD
- drift detection
- automatic drift remediation
- Git and Kubernetes state convergence
- restricted Argo CD project boundaries

## Current Resource Ownership

Terraform owns:

- Argo CD bootstrap installation
- bootstrap Kubernetes resources required before GitOps

Argo CD owns:

- `demo-dev` namespace
- GitOps-managed application resources

Git stores:

- desired state
- AppProject definitions
- Application definitions
- non-sensitive configuration

Repository credentials remain outside Git and Terraform state.

## Remaining Validation

Future platform phases will validate:

- automated pruning
- Helm-based application delivery
- rolling application updates
- rollback behavior
- health probes
- resource requests and limits
- security contexts
- horizontal autoscaling
- CI validation
- Kafka reconciliation and application integration
