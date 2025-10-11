Sealed Secrets Setup

This repo deploys the Bitnami Sealed Secrets controller via Argo CD (`root/apps/sealed-secrets.yaml`).

Steps to create sealed secrets for LDAP and the auth gateway:

1) Install kubeseal (workstation)
- macOS: `brew install kubeseal`
- Linux: see https://github.com/bitnami-labs/sealed-secrets

2) (Optional) Fetch the cluster public key
- `kubeseal --controller-name=sealed-secrets-controller --controller-namespace kube-system --fetch-cert > sealed-secrets.pem`

3) Create the Kubernetes Secret manifests locally (do not commit)

ldap-admin.yaml
```
apiVersion: v1
kind: Secret
metadata:
  name: ldap-admin
  namespace: auth
stringData:
  LDAP_ADMIN_PASSWORD: "<strong-password>"
  LDAP_CONFIG_PASSWORD: "<strong-password>"
```

auth-gateway-secrets.yaml
```
apiVersion: v1
kind: Secret
metadata:
  name: auth-gateway-secrets
  namespace: auth
stringData:
  JWT_SECRET: "<32+ char random>"
  SESSION_SECRET: "<32+ char random>"
  STORAGE_ENCRYPTION_KEY: "<32+ char random>"
  LDAP_PASSWORD: "<matches LDAP_ADMIN_PASSWORD>"
```

4) Seal them and save as Git-tracked SealedSecret manifests

Option A (auto fetch cert)
```
kubeseal -o yaml < ldap-admin.yaml > apps/auth/ldap-admin.sealed.yaml \
  --controller-name=sealed-secrets-controller --controller-namespace=kube-system

kubeseal -o yaml < auth-gateway-secrets.yaml > apps/auth/auth-gateway-secrets.sealed.yaml \
  --controller-name=sealed-secrets-controller --controller-namespace=kube-system
```

Option B (use fetched cert)
```
kubeseal --cert sealed-secrets.pem -o yaml < ldap-admin.yaml > apps/auth/ldap-admin.sealed.yaml
kubeseal --cert sealed-secrets.pem -o yaml < auth-gateway-secrets.yaml > apps/auth/auth-gateway-secrets.sealed.yaml
```

5) Commit the sealed secrets
- Add the generated files under `apps/auth/` to Git and push.

6) Ensure they are applied
- Add the files to a Kustomization under `apps/auth/kustomization.yaml` or include them in an existing app path applied by Argo CD.
- Alternatively: `kubectl apply -f apps/auth/`.

Notes
- LDAP and auth-gateway Deployments reference these Secrets by name; they become usable once decrypted by the controller.
- Rotate by re-sealing a new Secret with the same name/namespace.
