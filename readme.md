# homelab-cluster

A declarative, version-controlled kubernetes cluster managed using continuous delivery.

## prerequisites

- Podman, if building the cluster with Kubespray from this repo.
- kubectl configured for the cluster before bootstrapping apps. When Kubespray is
  run by `scripts/full-bootstrap.sh`, the script uses local `ssh` and `scp` to fetch
  `/etc/kubernetes/admin.conf` from the first control-plane host to
  `infrastructure/artifacts/admin.conf` and uses it for the remaining bootstrap
  steps.

## Full Bootstrap

The preferred entrypoint is the full bootstrap helper. It can run Kubespray from
a pinned container image, install Argo CD and Sealed Secrets, seal required
secret inputs into repo manifests, register the source repository, create the
root `Application`, and validate the bootstrap state.

```shell
cp infrastructure/hosts.example.yaml infrastructure/hosts.yaml
$EDITOR infrastructure/hosts.yaml

./scripts/full-bootstrap.sh \
  --provision-cluster \
  --hosts infrastructure/hosts.yaml \
  --domain home.arpa \
  --load-balancer-addresses 192.0.2.30-192.0.2.40 \
  --ca-crt path/to/intermediate-ca.crt \
  --ca-key path/to/intermediate-ca.key \
  --admin-username your-username \
  --admin-email you@home.arpa \
  --ssh-private-key ~/.ssh/id_rsa \
  --ssh-known-hosts ~/.ssh/known_hosts
```

If the kubernetes cluster already exists, omit `--provision-cluster`:

```shell
./scripts/full-bootstrap.sh \
  --ca-crt path/to/intermediate-ca.crt \
  --ca-key path/to/intermediate-ca.key
```

The script is safe to run multiple times. It preserves existing live secret
values when generating sealed manifests and registers the root source repository
before creating the root `Application`.

Inputs that affect declared cluster state update the repo manifests. If
`--domain`, `--load-balancer-addresses`, or required sealed secrets change
files, the script stops so you can commit and push the new desired state, then
rerun bootstrap. On a fresh cluster this means the first run installs Argo CD
and Sealed Secrets, writes encrypted `SealedSecret` manifests to `apps/`, and
exits before dependent apps need those secrets.

## Ownership

Argo CD owns the manifests under `root/` and `apps/`. The bootstrap scripts only
create prerequisites needed before those apps can become healthy:

- `apps/cert-manager/internal-ca.sealed.yaml`: sealed intermediate CA secret.
- `apps/ldap/ldap-admin.sealed.yaml`: sealed LDAP admin secret.
- `apps/auth-gateway/auth-gateway-secrets.sealed.yaml`: sealed auth gateway
  secret material.
- `apps/auth-gateway/auth-admin-user.sealed.yaml`: sealed LDAP admin user
  credentials for central SSO.
- `auth/ldap-bootstrap-identity`: temporary idempotent Job that seeds LDAP.
- `argocd/source-repository`: declared in `apps/argocd-config` and applied by
  bootstrap early so Argo CD shows the root repository immediately.

Existing runtime secret values are preserved on reruns. Inputs that affect
declared manifests are written to files in this repo instead of patched directly
in the cluster.

Argo CD uses the auth gateway as its OIDC provider and maps the LDAP `admins`
group to Argo CD admin access. The built-in Argo CD admin account is disabled in
the declared configuration.

The script can be overridden with environment variables:

- `ARGOCD_VERSION`: upstream Argo CD install manifest tag, default `v3.1.8`.
- `KUBESPRAY_IMAGE`: Kubespray container image, default
  `quay.io/kubespray/kubespray:v2.31.0`.
- `KUBESPRAY_PLAYBOOK`: Kubespray playbook, default `cluster.yml`.
- `KUBECONFIG_SSH_TARGET`: SSH target used to fetch
  `/etc/kubernetes/admin.conf`, default first `kube_control_plane` inventory
  host.
- `ARGOCD_CLI_LOGIN`: log the local `argocd` CLI in through SSO after bootstrap
  when the CLI is installed, default `false`.
- `ARGOCD_CLI_SERVER`: Argo CD ingress hostname used for `argocd login`,
  default `argocd.home.arpa`.
- `ARGOCD_CLI_SSO`: use browser SSO for `argocd login`, default `true`.
- `ARGOCD_CLI_INSECURE`: disable TLS certificate verification for `argocd
  login`, default `false`.
- `BOOTSTRAP_GENERATED_SECRET_BYTES`: random byte length for generated
  bootstrap secrets, default `48`.
- `AUTH_ADMIN_USERNAME`: LDAP admin username, default `admin`.
- `AUTH_ADMIN_EMAIL`: LDAP admin email address, default `admin@home.arpa`.
- `CLUSTER_DOMAIN`: base DNS domain used for service manifests and printed URLs,
  default `home.arpa`.

After a successful run, admin credentials are written to
`infrastructure/artifacts/bootstrap-credentials.txt`. The provided intermediate
CA certificate is copied to `infrastructure/artifacts/internal-ca.crt` for
workstation trust setup.

## Internal CA Secret

Cert-manager issues cluster certificates from an internal CA secret that must be
present in the `cert-manager` namespace. The repo does not generate or require
your root authority key. Provide an intermediate CA certificate and private key
signed by your root authority:

```shell
./scripts/full-bootstrap.sh --ca-crt path/to/ca.crt --ca-key path/to/ca.key
```

The bootstrap seals that intermediate CA into
`apps/cert-manager/internal-ca.sealed.yaml` and adds it to the cert-manager
kustomization. Commit and push the generated sealed manifest before rerunning
bootstrap so Argo CD can create the live `internal-ca` Secret.

To rerun only the CA sealing step after Sealed Secrets exists in the cluster:

```shell
./scripts/provision-internal-ca.sh path/to/ca.crt path/to/ca.key
```

## Argo CD Only Bootstrap

For a cluster where required sealed secrets are already committed, run the lower-level
Argo CD bootstrap helper to install Argo CD, create the root `Application`, and
hand control over to Argo CD:

```shell
./scripts/bootstrap-cluster.sh
```

## Sync Order

Argo CD applications are assigned sync waves to ensure platform dependencies
(such as cert-manager) finish installing before dependent configuration applies.

## Validation

`scripts/full-bootstrap.sh` validates that the root `Application` exists, the
root source repository is registered, and, when the `argocd` CLI is available,
that Argo CD can read both through the configured ingress.
