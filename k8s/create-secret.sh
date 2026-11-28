#!/usr/bin/env bash
# Create or update the devops-task-secret in the cluster. The value never touches git.
# Usage: APP_API_KEY=my-value ./k8s/create-secret.sh   (random value is generated if unset)
set -euo pipefail

NAMESPACE="${NAMESPACE:-devops-task}"
APP_API_KEY="${APP_API_KEY:-$(openssl rand -hex 16)}"

kubectl create secret generic devops-task-secret \
  --namespace "$NAMESPACE" \
  --from-literal=APP_API_KEY="$APP_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
