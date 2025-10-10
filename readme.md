# homelab-cluster

A declarative, version-controlled kubernetes cluster managed by Argo CD.

## Bootstrap

Run the bootstrap helper to install argocd (pinned to `v2.12.3`), create the
root `Application`, and hand control over to argocd:

```shell
./scripts/bootstrap-cluster.sh
```

The script can be overridden with a different upstream Argo CD tag by setting
`ARGOCD_VERSION`. It is safe to run multiple times.

## Internal CA Secret

// TODO: Implement a completely automated alternative for those who don't want 
// to use their own certificate authority.

// TODO: Use sealed secrets (i.e. kubeseal) to limit out of band (i.e. manual)
// requirements.

Cert-manager issues cluster certificates from an internal CA secret that must be
provisioned out of band. Supply the CA certificate and key used by
`apps/cert-manager/internal-ca-issuer.yaml`:

```shell
./scripts/provision-internal-ca.sh path/to/ca.crt path/to/ca.key
```

The script validates the inputs, ensures the `cert-manager` namespace exists,
and creates or updates the `internal-ca` secret that backs the
`internal-ca-issuer` `ClusterIssuer`.

## Sync Order

Argo CD applications are assigned sync waves to ensure platform dependencies
(such as cert-manager) finish installing before dependent configuration applies.

## Validation

// TODO: Implement some validation/feedback mechanism. Right now I have to use
// argo ui or cli to figure out if things are okay. Ideally, validate as much 
// as possible before changing the cluster, but at least notify on deployment
// issues or make them readily available.
