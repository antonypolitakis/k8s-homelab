#!/usr/bin/env bash
# Rebuild the homelab cluster from scratch. Everything else comes from Git via Argo CD.
set -euo pipefail
cd "$(dirname "$0")"   # run from the repo root, wherever the script is called from

# 1. Cluster (3 nodes; Mac ports 80/443/25565 forwarded in)
kind create cluster --config cluster/kind-config.yaml

# 2. Local CA for HTTPS. Made once on the Mac and kept OUT of Git (see docs/https.md).
#    cert-manager's ClusterIssuer "homelab-ca" signs certificates with it.
CA_DIR="$HOME/.homelab-ca"
if [[ -f "$CA_DIR/ca.key" && -f "$CA_DIR/ca.crt" ]]; then
  kubectl create namespace cert-manager
  kubectl create secret tls homelab-ca -n cert-manager \
    --cert="$CA_DIR/ca.crt" --key="$CA_DIR/ca.key"
else
  echo "WARNING: no CA in $CA_DIR - HTTPS certificates won't be issued (see docs/https.md)"
fi

# 3. Argo CD, with our settings (ingress at argocd.localhost, plain HTTP behind Traefik)
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.14.0 \
  -f argocd/values.yaml
kubectl wait --for=condition=available deploy --all -n argocd --timeout=300s

# 4. Hand over to Git: root deploys everything in argocd/apps/ (Argo CD itself, Traefik,
#    cert-manager, podinfo, Minecraft...). Helm isn't used again after this.
kubectl apply -f argocd/root.yaml

# 5. Wait for the ingress controller, so the URLs below work when we finish
echo "Waiting for Traefik..."
until kubectl get application traefik -n argocd >/dev/null 2>&1; do sleep 2; done
kubectl wait application/traefik -n argocd \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s

echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
echo
echo "Argo CD:   https://argocd.localhost   (user: admin)"
echo "podinfo:   https://podinfo.localhost"
echo "(certificates take ~1 min after this to be issued)"
echo "Minecraft: localhost:25565"
