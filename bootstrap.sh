#!/usr/bin/env bash
# Rebuild the homelab cluster from scratch. Everything else comes from Git via Argo CD.
set -euo pipefail
cd "$(dirname "$0")"   # run from the repo root, wherever the script is called from

# 1. Cluster (3 nodes; Mac ports 80/443/25565 forwarded in)
kind create cluster --config cluster/kind-config.yaml

# 2. Argo CD, with our settings (ingress at argocd.localhost, plain HTTP behind Traefik)
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.14.0 \
  -f argocd/values.yaml
kubectl wait --for=condition=available deploy --all -n argocd --timeout=300s

# 3. Hand over to Git: root deploys everything in argocd/apps/ (Traefik, podinfo, Minecraft...)
kubectl apply -f argocd/root.yaml

# 4. Wait for the ingress controller, so the URLs below work when we finish
echo "Waiting for Traefik..."
until kubectl get application traefik -n argocd >/dev/null 2>&1; do sleep 2; done
kubectl wait application/traefik -n argocd \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s

echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
echo
echo "Argo CD:   http://argocd.localhost   (user: admin)"
echo "podinfo:   http://podinfo.localhost"
echo "Minecraft: localhost:25565"
