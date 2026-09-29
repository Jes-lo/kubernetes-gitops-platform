# Third-Party Notices

This project uses third-party software, tools, libraries, container images,
and services as part of its development, bootstrap, validation, and runtime
environment.

Third-party components remain the property of their respective copyright
holders and are subject to their respective licenses and terms.

## Components Currently Used

| Component | Version / Reference | Project Use | License |
|---|---|---|---|
| Kubernetes | v1.36.4 | Local Kubernetes platform | Apache-2.0 |
| kind | v0.33.0 | Local Kubernetes cluster lifecycle | Apache-2.0 |
| Helm | v4.3.0 | Kubernetes package management | Apache-2.0 |
| Terraform | v1.16.4 | Platform bootstrap Infrastructure as Code | BUSL-1.1 |
| Terraform Kubernetes Provider | v3.2.1 | Kubernetes bootstrap resources | MPL-2.0 |
| Terraform Helm Provider | v3.3.0 | Helm release management during bootstrap | MPL-2.0 |
| Argo CD | v3.5.3 | GitOps reconciliation and continuous delivery | Apache-2.0 |
| Argo CD Helm Chart | 10.9.2 | Argo CD installation | Apache-2.0 |
| actions/checkout | v7.0.1 | GitHub Actions repository checkout | MIT |
| hashicorp/setup-terraform | v4.0.1 | Terraform setup in CI | MPL-2.0 |
| Aqua Security Trivy Action | v0.36.0 | Security scanning in CI | Apache-2.0 |
| Aqua Security Trivy | v0.74.0 | IaC misconfiguration and secret scanning | Apache-2.0 |
| Node.js | v24.21.0 LTS | Demo API runtime | MIT |
| nodejs/docker-node | 24.21.0-bookworm-slim, digest-pinned | Demo API container base packaging | MIT |

Docker and Docker Desktop are used as external local development/runtime
tooling and remain subject to Docker's applicable licenses and terms.

GitHub Container Registry (GHCR) is used as an external container registry
service and remains subject to GitHub's applicable terms and policies.

## Repository-Owned Material

Repository-specific source code, Infrastructure as Code, Kubernetes
configuration, Helm packaging, automation, documentation, tests, diagrams,
architecture decisions, and integrations are created specifically for this
portfolio project unless otherwise identified as third-party material.

The repository does not claim ownership of Kubernetes, kind, Helm, Terraform,
Argo CD, Docker, or any other third-party technology used by the project.

Third-party names and trademarks are used only for identification,
interoperability, documentation, and description of the technologies used.

## Third-Party Source Code

No third-party source code is intentionally copied or vendored into this
repository unless explicitly documented.

Dependencies downloaded by package managers, Terraform providers, container
images, Helm charts, and other externally distributed artifacts remain subject
to their original licenses and terms.

Additional third-party components will be documented here as they are
introduced into the project.
