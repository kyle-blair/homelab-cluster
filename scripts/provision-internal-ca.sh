#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: ${0##*/} <path-to-ca-crt> <path-to-ca-key>

Creates/updates the cert-manager secret that backs the internal CA issuer.
USAGE
}

if [ "$#" -ne 2 ]; then
  usage
  exit 64
fi

CERT_PATH=$1
KEY_PATH=$2
SECRET_NAME=${SECRET_NAME:-internal-ca}
NAMESPACE=${NAMESPACE:-cert-manager}

if [ ! -f "$CERT_PATH" ]; then
  echo "CA certificate not found at $CERT_PATH" >&2
  exit 66
fi

if [ ! -f "$KEY_PATH" ]; then
  echo "CA private key not found at $KEY_PATH" >&2
  exit 66
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace $NAMESPACE not present. Ensure the cert-manager application has synced before running this script." >&2
  exit 69
fi

echo "[internal-ca] Creating/updating secret $SECRET_NAME in namespace $NAMESPACE"
kubectl create secret tls "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --cert "$CERT_PATH" \
  --key "$KEY_PATH" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

echo "[internal-ca] Secret $SECRET_NAME is ready."
