# Sealed Secrets

This repo deploys the Bitnami Sealed Secrets controller via Argo CD
(`root/apps/sealed-secrets.yaml`). Cluster secrets that are hard dependencies
for repo-defined services are stored as encrypted `SealedSecret` manifests under
`apps/` and are decrypted in-cluster by that controller.

## Bootstrap workflow

Install `kubeseal` on the workstation before running the full bootstrap:

- macOS: `brew install kubeseal`
- Linux: install from the Bitnami Sealed Secrets project releases

On a fresh cluster, run:

```shell
./scripts/full-bootstrap.sh \
  --ca-crt path/to/intermediate-ca.crt \
  --ca-key path/to/intermediate-ca.key
```

The first pass installs Argo CD and Sealed Secrets, then writes any missing
sealed secret manifests:

- `apps/cert-manager/internal-ca.sealed.yaml`
- `apps/ldap/ldap-admin.sealed.yaml`
- `apps/auth-gateway/auth-gateway-secrets.sealed.yaml`
- `apps/auth-gateway/auth-admin-user.sealed.yaml`

Commit and push those generated files, then rerun `scripts/full-bootstrap.sh`.
Argo CD will sync the committed desired state, the Sealed Secrets controller
will create the live Kubernetes Secrets, and the script will continue through
LDAP admin user seeding and validation.

The internal CA must be an intermediate CA that you provide. The repo and
bootstrap scripts do not create or require your root authority key.

## Rotation

Rotate a secret by creating a new Kubernetes Secret manifest with the same
`metadata.name` and `metadata.namespace`, sealing it with `kubeseal`, and
replacing the corresponding `*.sealed.yaml` file in `apps/`.

For the internal CA only, this helper performs the local manifest creation and
sealing:

```shell
./scripts/provision-internal-ca.sh path/to/intermediate-ca.crt path/to/intermediate-ca.key
```

Commit and push the changed sealed manifest so Argo CD can sync it. Do not apply
replacement Secrets directly to the cluster; that bypasses the repo-owned state
and can leave Argo CD reporting drift.
