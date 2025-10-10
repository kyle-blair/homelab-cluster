#!/usr/bin/env bash
set -euo pipefail

: "${ARGOCD_VERSION:=v2.12.3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[bootstrap] Ensuring argocd namespace exists"
kubectl apply -f "${REPO_ROOT}/bootstrap/argocd-namespace.yaml"

echo "[bootstrap] Installing Argo CD components (${ARGOCD_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "[bootstrap] Creating Argo CD root application"
kubectl apply -f "${REPO_ROOT}/bootstrap/argocd-root-app.yaml"
