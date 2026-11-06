#!/usr/bin/env bash
# Rebuild the homelab cluster from scratch. Everything else comes from Git via Argo CD.
set -euo pipefail

kind create cluster --config cluster/kind-config.yaml

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.14.0
kubectl wait --for=condition=available deploy --all -n argocd --timeout=300s

kubectl apply -f argocd/root.yaml

echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secssword}" | base64 -d; echo
echo "UI: kubectl port-forward svc/argocd-server -n a//localhost:8080"
