set -euo pipefail

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Reconciliation mode (argocd|snapshot|fluxcd)
RECONCILE_MODE="${DUPLICATI_POST_BACKUP_RECONCILE:-argocd}"

# Snapshot directory and file (used in snapshot mode)
SNAPSHOT_DIR="${DUPLICATI_SCALE_SNAPSHOT_DIR:-/var/lib/duplicati/scale-snapshots}"
SNAPSHOT_FILE=""

# Logging functions for Duplicati integration
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting post-backup script..."

# Handle fluxcd mode - fail fast
if [ "$RECONCILE_MODE" = "fluxcd" ]; then
  log_error "FluxCD reconciliation mode is not yet implemented. Please use 'argocd' or 'snapshot' mode instead."
  exit 1
fi

# Setup snapshot mode
if [ "$RECONCILE_MODE" = "snapshot" ]; then
  log_info "Snapshot mode enabled - restoring workloads from snapshot"

  # Find the latest snapshot file by modification time
  if [ -d "$SNAPSHOT_DIR" ]; then
    # shellcheck disable=SC2012
    SNAPSHOT_FILE=$(ls -t "$SNAPSHOT_DIR"/snapshot-*.json 2>/dev/null | head -n 1 || echo "")
  fi

  if [ -z "$SNAPSHOT_FILE" ]; then
    log_error "No snapshot file found in $SNAPSHOT_DIR. Cannot restore workloads."
    exit 1
  fi

  if [ ! -r "$SNAPSHOT_FILE" ]; then
    log_error "Snapshot file is not readable: $SNAPSHOT_FILE"
    exit 1
  fi

  log_info "Using snapshot file: $SNAPSHOT_FILE"

  # Restore workloads from snapshot
  restored_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines
    [ -z "$line" ] && continue

    # Parse JSON and extract fields
    kind=$(echo "$line" | jq -r '.kind' 2>/dev/null || echo "")
    namespace=$(echo "$line" | jq -r '.namespace' 2>/dev/null || echo "")
    name=$(echo "$line" | jq -r '.name' 2>/dev/null || echo "")
    replicas=$(echo "$line" | jq -r '.replicas' 2>/dev/null || echo "")

    [ -z "$kind" ] && continue
    [ -z "$namespace" ] && continue
    [ -z "$name" ] && continue
    [ -z "$replicas" ] && continue

    log_info "Restoring $kind: $namespace/$name (replicas -> $replicas)"

    if k3s kubectl scale "$kind" "$name" -n "$namespace" --replicas="$replicas" 2>/dev/null; then
      restored_count=$((restored_count + 1))
    else
      log_error "Failed to restore $kind: $namespace/$name (may have been deleted)"
    fi
  done < "$SNAPSHOT_FILE"

  log_info "Restored $restored_count workloads from snapshot"

  # Wait for restored workloads to be ready (best effort, non-blocking)
  if [ "$restored_count" -gt 0 ]; then
    log_info "Waiting for restored workloads to be ready..."
    timeout 180 k3s kubectl wait --for=condition=available -A --timeout=180s deployments --all || true
    timeout 180 k3s kubectl wait --for=condition=ready -A --timeout=180s statefulsets --all || true
  fi

  log_info "Snapshot restore completed"
  exit 0
fi

# argocd mode - restore ArgoCD namespace resources only
# Step 1: Scale up ArgoCD deployments and statefulsets
# This restores ArgoCD's ability to reconcile applications
# TODO: Implement proper ArgoCD app pause/resume via CLI or API
log_info "Scaling up ArgoCD resources..."

# Default ArgoCD replica counts (standard installation values)
# Application controller, repo server, and server typically run 1 replica each
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
