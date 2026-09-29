# Demo API GitOps Delivery Validation

Date: 2026-09-29

## Scope

Validated end-to-end GitOps delivery of `demo-api` through Argo CD using Helm and a private GHCR image.

## Git and image

Argo CD revision:

`f013fc3ee46bc3c6e7e8e8f9ed92dfbf7f7719ab`

Immutable image:

`ghcr.io/jes-lo/kubernetes-gitops-platform-demo-api@sha256:d6fc29d05e268a9052c36d5ced37927c61b124e9b7c3aabd76e8444296bfbdb4`

Runtime image pull secret: `ghcr-read`.

The registry credential is not stored in Git.

## Delivery result

Argo CD reached:

```text
sync=Synced
health=Healthy
revision=f013fc3ee46bc3c6e7e8e8f9ed92dfbf7f7719ab
```

Argo CD created and manages the Deployment, Service, and ServiceAccount.

The Deployment reached 2 desired and 2 ready replicas. Both Pods were `Running` with zero restarts.

The Service exposes port 80 and targets container port 3000. Its EndpointSlice contained both Pod addresses.

## Application checks

Validated responses:

```text
GET /          -> {"service":"demo-api","status":"running"}
GET /healthz   -> {"status":"ok"}
GET /readyz    -> {"status":"ready"}
GET /version   -> {"version":"0.1.0"}
```

## Runtime security

The container ran as:

```text
uid=1000(node)
gid=1000(node)
CapEff=0000000000000000
NoNewPrivs=1
Seccomp=2
```

A write attempt to `/app` failed with `Read-only file system`.

This validated non-root execution, zero effective Linux capabilities, no-new-privileges, seccomp filtering, and a read-only root filesystem.

## GitOps self-healing

Initial state:

```text
specReplicas=2
readyReplicas=2
sync=Synced
health=Healthy
```

Controlled drift was introduced by manually scaling the Deployment to 1 replica.

By the first observation, Argo CD had already restored the desired specification:

```text
specReplicas=2
readyReplicas=1
sync=Synced
health=Progressing
```

Final state:

```text
specReplicas=2
readyReplicas=2
sync=Synced
health=Healthy
revision=f013fc3ee46bc3c6e7e8e8f9ed92dfbf7f7719ab
```

No Git change was required to restore the Deployment.

## Result

Validation passed. The platform demonstrated Git as the source of truth, automated Argo CD reconciliation, Helm-based workload delivery, immutable image deployment by SHA256 digest, private GHCR pulling, hardened runtime controls, health/readiness checks, and automatic remediation of manual drift.
