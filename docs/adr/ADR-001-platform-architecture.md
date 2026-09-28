# ADR-001: Kubernetes GitOps Platform Architecture

## Status

Accepted

## Date

2026-09-28

## Context

This project demonstrates a Kubernetes platform where infrastructure
bootstrap, application packaging, continuous validation, and GitOps
reconciliation have clearly separated responsibilities.

The implementation must remain practical for a local portfolio environment
while representing patterns that can be explained and evolved toward larger
platforms.

The platform must also avoid treating CI as the Kubernetes deployment
mechanism.

Git must remain the source of truth for workloads managed through GitOps.

## Decision

Use a local Kubernetes cluster created with kind.

The initial development topology will contain:

- one Kubernetes control-plane node
- two Kubernetes worker nodes

The platform will use the following responsibility boundaries.

### kind

kind is responsible only for creating and deleting the local Kubernetes
cluster.

Cluster topology and local node configuration are stored in the repository.

### Terraform

Terraform is responsible for bootstrap infrastructure that must exist before
GitOps reconciliation can begin.

The initial Terraform scope is intentionally limited to bootstrapping Argo CD
and its required Kubernetes resources.

Terraform will not manage application workloads that are owned by Argo CD.

### Argo CD

Argo CD is responsible for reconciling Kubernetes platform components and
application workloads from Git.

Git is the desired-state source for resources managed by Argo CD.

CI workflows will not directly deploy application manifests with
`kubectl apply`.

### Helm

Helm is used to package the demonstration application.

The chart remains reusable while environment-specific desired state is defined
by the GitOps configuration.

### Kafka

Kafka is included as an intentional platform capability rather than as a
decorative dependency.

Strimzi will manage Kafka resources inside Kubernetes.

The development environment will use a deliberately small Kafka topology
appropriate for a local laboratory.

The project does not claim production Kafka availability or durability.

### GitHub Actions

GitHub Actions performs continuous validation.

Its responsibilities will include areas such as:

- application testing
- container build validation
- Helm validation
- Kubernetes manifest validation
- Terraform validation
- policy and security checks introduced by the project

GitHub Actions is not the Kubernetes deployment controller.

### Container Registry

A container registry will be introduced after the local application and
Kubernetes foundation are working.

GHCR is the intended registry for repository-produced application images.

## Kubernetes Namespaces

The initial namespace model is:

- `argocd` for the GitOps controller
- `platform-kafka` for Kafka and its operator-managed resources
- `demo-dev` for the demonstration workload

Additional namespaces must have a documented platform requirement before they
are introduced.

## GitOps Model

The initial repository uses a monorepo model.

Application source code, Helm packaging, platform configuration, and GitOps
desired state are kept in the same repository but remain separated by
directory and ownership boundaries.

The intended reconciliation path is:

Developer or dependency update
-> Git change
-> pull request
-> automated validation
-> merge to main
-> Argo CD detects desired-state change
-> Argo CD reconciles Kubernetes

## Bootstrap Boundary

The bootstrap sequence is:

1. create the kind cluster
2. initialize Terraform
3. bootstrap Argo CD
4. connect Argo CD to the Git repository
5. allow Argo CD to reconcile platform and application desired state

After bootstrap, application deployment is not performed through Terraform.

## Security Principles

The platform will prefer:

- non-root workloads
- explicit CPU and memory requests and limits
- readiness and liveness probes
- immutable or controlled image references
- namespace isolation
- Kubernetes security contexts
- least-privilege permissions
- declarative configuration
- no committed credentials
- explicit ownership boundaries between Terraform and Argo CD

Additional controls will be introduced only when they have a concrete purpose
in the platform.

## Alternatives Considered

### Terraform manages all Kubernetes workloads

Rejected because it would blur the ownership boundary between Infrastructure
as Code and GitOps reconciliation.

### GitHub Actions deploys with kubectl

Rejected because direct CI deployment would bypass the GitOps reconciliation
model this project is intended to demonstrate.

### Single-node Kubernetes only

Not selected as the default because two worker nodes provide additional
platform-engineering exercises such as scheduling and workload distribution.

### Production-sized Kafka cluster

Rejected for the development environment because the resource cost and
operational complexity would not provide proportional portfolio value.

## Consequences

### Positive

- clear separation between bootstrap and reconciliation
- Git remains the desired-state source
- Terraform retains a meaningful infrastructure role
- the platform can be recreated locally
- the architecture can later evolve toward cloud Kubernetes
- Kafka has a defined functional purpose

### Trade-offs

- the local environment does not represent production availability
- bootstrap requires both kind and Terraform
- a private Git repository requires explicit Argo CD repository
  authentication
- local resource consumption is higher than a single-node laboratory

These trade-offs are intentional and must not be described as production
characteristics.
