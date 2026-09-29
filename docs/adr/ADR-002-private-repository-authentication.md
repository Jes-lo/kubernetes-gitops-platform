# ADR-002: Private Git Repository Authentication

## Status

Accepted

## Date

2026-09-29

## Context

Argo CD requires read access to the private GitHub repository that stores the
desired state of the Kubernetes GitOps platform.

Repository authentication must follow least-privilege principles and must not
introduce credentials into Git history or Terraform state.

The authentication mechanism should also remain practical for a single-repository
portfolio environment.

## Decision

Use a dedicated SSH deploy key for the private GitHub repository.

The deploy key will:

- be dedicated to this repository
- have read-only access
- not be reused as a personal SSH key
- not be committed to Git
- not be managed through Terraform
- be stored in Kubernetes as an Argo CD repository Secret
- exist locally only in a protected file while required for administration

The public key will be registered as a GitHub repository deploy key.

The private key will be provided to Argo CD through a Kubernetes Secret in the
`argocd` namespace.

## Repository Scope

The authentication credential is intentionally scoped to:

`Jes-lo/kubernetes-gitops-platform`

It must not provide write access to the repository.

Argo CD is expected to read Git desired state.

Argo CD will not push changes back to the repository as part of the initial
GitOps architecture.

## Secret Ownership

Git stores:

- repository URL
- Argo CD Application definitions
- declarative desired state
- non-sensitive configuration

Git does not store:

- SSH private keys
- personal access tokens
- repository credentials
- generated Kubernetes Secret values

Terraform does not manage the Git repository credential.

This prevents the repository private key from being stored in Terraform state.

## SSH Host Verification

Argo CD must verify the SSH host key for GitHub.

Host-key verification must not be disabled.

The existing Argo CD SSH known-host configuration will be inspected before
repository credentials are configured.

## Alternatives Considered

### Personal Access Token

Not selected for the initial implementation.

A personal access token would associate repository access with a user credential
and could have a broader permission scope than required by this platform.

### GitHub App

Not selected for the initial single-repository implementation.

GitHub App authentication provides a strong model for installations that need
controlled access to multiple repositories and can be introduced later if the
platform expands.

For the current single-repository environment, a repository-scoped read-only
deploy key provides a simpler least-privilege model.

### Write-Enabled Deploy Key

Rejected.

Argo CD only requires repository read access for the initial reconciliation
model.

Granting write access would violate the least-privilege objective.

### Disabling SSH Host-Key Verification

Rejected.

Repository authentication must verify the identity of the Git server.

## Consequences

### Positive

- repository-specific access
- read-only Git permissions
- no personal token required by Argo CD
- credentials remain outside Git
- credentials remain outside Terraform state
- simple credential revocation through GitHub
- clear separation between GitOps desired state and secret material

### Trade-offs

- the deploy key is specific to one repository
- a separate key would normally be required for another private repository
- the private key must still be securely managed inside Kubernetes
- credential rotation is a manual operational process

If the platform later manages multiple repositories, GitHub App authentication
can be reconsidered.
