# Security Policy

## Scope

This repository is a portfolio and engineering demonstration project for
Kubernetes, GitOps, infrastructure automation, and platform security practices.

Security issues relevant to this repository may include:

- accidentally committed credentials or secrets;
- exposed Kubernetes credentials or kubeconfig files;
- exposed Git or container registry credentials;
- private SSH or Git deploy keys;
- private TLS keys or certificates containing sensitive key material;
- unsafe Kubernetes, Helm, Terraform, Argo CD, Strimzi, or Kafka configuration;
- overly permissive RBAC or Kafka authorization;
- insecure CI/CD or GitOps configuration;
- unintended privilege escalation;
- insecure container runtime configuration;
- security-sensitive documentation errors.

## Reporting a security issue

Do not publish credentials, secrets, tokens, private keys, kubeconfig files,
certificates containing private key material, or other sensitive information
in a public issue.

When private vulnerability reporting is available through GitHub, use that
mechanism.

Otherwise, contact the repository owner privately before disclosing sensitive
details publicly.

## Credentials and secrets

This repository must not contain:

- Kubernetes cluster credentials;
- kubeconfig files containing credentials;
- GitHub personal access tokens;
- container registry credentials;
- private SSH keys;
- Git deploy private keys;
- private TLS keys;
- cloud access credentials;
- passwords or API tokens;
- production credentials;
- real customer data;
- employer confidential information.

Runtime credentials and secrets should be generated or supplied through
appropriate local, Kubernetes, CI, or ephemeral mechanisms rather than being
stored directly in Git.

## GitOps and infrastructure changes

Changes to Kubernetes manifests, Helm configuration, Terraform, Argo CD,
Strimzi, Kafka, container configuration, and repository security controls
should be reviewed and validated before merge.

Automated validation should be used where applicable to detect configuration,
security, and repository-policy issues before changes reach the maintained
branch.

Git remains the source of truth for declarative platform configuration.
Security-sensitive runtime values should not be committed solely to make
GitOps reconciliation easier.

## Security findings

Security findings produced by automated validation or security tooling should
be reviewed individually.

Suppressions or exceptions should include a documented technical
justification rather than disabling security controls globally.

If a credential or sensitive value is accidentally exposed, revoking or
rotating it is required; removing it from the repository alone is not
considered sufficient remediation.

## Supported versions

This repository represents an actively developed portfolio project rather than
a versioned production software product.

Only the current `main` branch is considered maintained.
