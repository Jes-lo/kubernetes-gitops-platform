# Kubernetes GitOps Platform

A greenfield portfolio implementation of a Kubernetes platform focused on
GitOps reconciliation, Infrastructure as Code, application packaging,
platform automation, and declarative operations.

## Project Status

**Implemented local Kubernetes GitOps platform**

The current development environment includes a reproducible kind cluster,
Terraform-based Argo CD bootstrap, GitOps reconciliation, a containerized demo
application delivered from GHCR, and a Strimzi-managed Kafka platform with TLS
authentication and least-privilege authorization.

The platform includes automated bootstrap, validation, credential-lifecycle,
idempotency, and functional Kafka mTLS validation workflows.

## Objectives

The platform is designed to demonstrate practical experience with:

- Kubernetes
- GitOps
- Argo CD
- Terraform
- Helm
- Docker
- GitHub Actions
- Kafka with Strimzi
- declarative infrastructure and application delivery

## Architecture Responsibilities

| Component | Responsibility |
|---|---|
| kind | Local Kubernetes cluster lifecycle |
| Terraform | Platform bootstrap |
| Argo CD | GitOps reconciliation |
| Helm | Application packaging |
| Strimzi | Kafka operation in Kubernetes |
| GitHub Actions | Continuous validation |
| Git | Desired-state source |
| GHCR | Demo application image registry |

## Cluster Topology

The initial local development cluster is designed with:

- 1 control-plane node
- 2 worker nodes

Initial namespaces:

- `argocd`
- `platform-kafka`
- `demo-dev`

The topology is intentionally designed for development and demonstration.

It is not represented as a production Kubernetes architecture.

## GitOps Ownership Model

CI validates proposed changes.

Argo CD reconciles approved desired state from Git.

Application workloads are not deployed directly from GitHub Actions.

Terraform is responsible for bootstrap infrastructure and does not become a
second owner of workloads managed by Argo CD.

## Delivery Flow

Developer change
-> Pull Request
-> GitHub Actions validation
-> Merge to main
-> Argo CD reconciliation
-> Kubernetes

## Repository Structure

    .
    ├── .github/
    │   └── workflows/
    ├── app/
    │   └── demo-api/
    ├── charts/
    │   └── demo-api/
    ├── docs/
    │   ├── adr/
    │   ├── validation/
    │   └── REPRODUCIBILITY.md
    ├── gitops/
    │   ├── applications/
    │   ├── environments/
    │   │   └── dev/
    │   └── projects/
    ├── kind/
    │   └── cluster.yaml
    ├── platform/
    │   ├── argocd/
    │   └── kafka/
    ├── scripts/
    ├── terraform/
    │   └── bootstrap/
    ├── tests/
    └── Makefile

## Engineering Principles

- Git is the source of truth for GitOps-managed workloads.
- CI validates changes but does not directly deploy application workloads.
- Terraform and Argo CD must have explicit ownership boundaries.
- Credentials must not be committed to the repository.
- Workloads should use explicit security and resource configuration.
- Architecture decisions must be documented.
- Third-party software remains subject to its respective licenses.
- Repository-specific implementation is created for this portfolio project.

## Documentation

Architecture decisions are stored under `docs/adr/`.

The initial architecture decision is documented in
`docs/adr/ADR-001-platform-architecture.md`.

The secure clean-environment bootstrap, credential lifecycle,
idempotency behavior, validation workflow, and reproducibility model are
documented in [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md).

## Scope

This is a portfolio and development platform.

It does not claim:

- production high availability
- production Kafka durability
- a managed cloud Kubernetes service
- automatic production deployment
