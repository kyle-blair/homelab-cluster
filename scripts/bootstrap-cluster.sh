#!/usr/bin/env bash
set -euo pipefail

: "${ARGOCD_VERSION:=v3.1.8}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[bootstrap] Ensuring argocd namespace exists"
kubectl apply --filename "${REPO_ROOT}/bootstrap/argocd-namespace.yaml"

echo "[bootstrap] Installing Argo CD components (${ARGOCD_VERSION})"
kubectl apply --namespace argocd --filename "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "[bootstrap] Waiting for Argo CD Application CRD"
kubectl wait \
  --for condition=Established \
  --timeout=120s \
  crd/applications.argoproj.io

echo "[bootstrap] Registering root source repository"
kubectl apply --namespace argocd --filename "${REPO_ROOT}/apps/argocd-config/source-repository.yaml"

echo "[bootstrap] Creating Argo CD root application"
kubectl apply --namespace argocd --filename "${REPO_ROOT}/bootstrap/argocd-root-app.yaml"
