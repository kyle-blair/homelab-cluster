#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${REPO_ROOT}/apps/cert-manager/internal-ca.sealed.yaml"
KUSTOMIZATION="${REPO_ROOT}/apps/cert-manager/kustomization.yaml"
ARTIFACTS_DIR="${REPO_ROOT}/infrastructure/artifacts"

usage() {
  cat <<USAGE >&2
Usage: ${0##*/} <path-to-ca-crt> <path-to-ca-key>

Seals the cert-manager internal CA into apps/cert-manager/internal-ca.sealed.yaml.
The Sealed Secrets controller must already be installed in the target cluster.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 69
  fi
}

add_kustomization_resource() {
  local kustomization=$1
  local resource=$2

  if grep -qx "  - ${resource}" "$kustomization"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v resource="  - ${resource}" '
    BEGIN { in_resources = 0; inserted = 0 }
    /^resources:[[:space:]]*$/ {
      in_resources = 1
      print
      next
    }
    in_resources && /^[^[:space:]-][^:]*:/ {
      if (!inserted) {
        print resource
        inserted = 1
      }
      in_resources = 0
    }
    { print }
    END {
      if (in_resources && !inserted) {
        print resource
        inserted = 1
      }
      if (!inserted) {
        print "resources:"
        print resource
      }
    }
  ' "$kustomization" >"$tmp"
  mv "$tmp" "$kustomization"
}

if [ "$#" -ne 2 ]; then
  usage
  exit 64
fi

CERT_PATH=$1
KEY_PATH=$2

if [ ! -f "$CERT_PATH" ]; then
  echo "CA certificate not found at $CERT_PATH" >&2
  exit 66
fi

if [ ! -f "$KEY_PATH" ]; then
  echo "CA private key not found at $KEY_PATH" >&2
  exit 66
fi

require_command kubectl
require_command kubeseal

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

kubectl create secret tls internal-ca \
  --namespace cert-manager \
  --cert "$CERT_PATH" \
  --key "$KEY_PATH" \
  --dry-run=client \
  -o yaml >"${tmp_dir}/internal-ca.yaml"

kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  <"${tmp_dir}/internal-ca.yaml" >"$TARGET"

add_kustomization_resource "$KUSTOMIZATION" "internal-ca.sealed.yaml"
mkdir -p "$ARTIFACTS_DIR"
cp "$CERT_PATH" "${ARTIFACTS_DIR}/internal-ca.crt"

echo "[internal-ca] Wrote $TARGET"
echo "[internal-ca] Commit and push the repo change so Argo CD can sync the CA secret."
