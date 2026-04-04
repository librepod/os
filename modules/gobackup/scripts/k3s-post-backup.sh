set -euo pipefail

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions for gobackup integration
log_info() {
  echo "LOG:INFO $*"
}

log_info "Starting post-backup script..."

# Step 1: Scale up ArgoCD deployments and statefulsets
# This restores ArgoCD's ability to reconcile applications
log_info "Scaling up ArgoCD resources..."

# Default ArgoCD replica counts (standard installation values)
declare -A ARGOCD_DEFAULT_REPLICAS=(
  ["argocd-applicationset-controller"]=1
  ["argocd-notifications-controller"]=1
  ["argocd-repo-server"]=1
  ["argocd-server"]=1
  ["argocd-application-controller"]=1
)

# Scale up Deployments
argocd_deployments=$(k3s kubectl get deployments -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for deployment in $argocd_deployments; do
  if [ -n "$deployment" ]; then
    replicas=${ARGOCD_DEFAULT_REPLICAS[$deployment]:-1}
    log_info "Scaling up deployment: argocd/$deployment (replicas -> $replicas)"
    k3s kubectl scale deployment "$deployment" -n argocd --replicas="$replicas" 2>/dev/null || true
  fi
done

# Scale up StatefulSets
argocd_statefulsets=$(k3s kubectl get statefulsets -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for statefulset in $argocd_statefulsets; do
  if [ -n "$statefulset" ]; then
    replicas=${ARGOCD_DEFAULT_REPLICAS[$statefulset]:-1}
    log_info "Scaling up statefulset: argocd/$statefulset (replicas -> $replicas)"
    k3s kubectl scale statefulset "$statefulset" -n argocd --replicas="$replicas" 2>/dev/null || true
  fi
done

# Wait for ArgoCD to be ready
if [ -n "$argocd_deployments" ] || [ -n "$argocd_statefulsets" ]; then
  log_info "Waiting for ArgoCD resources to be ready..."
  timeout 180 k3s kubectl wait --for=condition=ready pod -n argocd -l app.kubernetes.io/part-of=argocd --timeout=180s 2>/dev/null || true
fi

log_info "Post-backup script completed successfully"
log_info "ArgoCD will now reconcile all applications to their desired state"
exit 0
