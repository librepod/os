set -euo pipefail

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STORAGE_CLASS=nfs-client

# Reconciliation mode (argocd|snapshot|fluxcd)
RECONCILE_MODE="${DUPLICATI_POST_BACKUP_RECONCILE:-argocd}"

# Snapshot directory and file (used in snapshot mode)
SNAPSHOT_DIR="${DUPLICATI_SCALE_SNAPSHOT_DIR:-/var/lib/duplicati/scale-snapshots}"
SNAPSHOT_FILE=""
SNAPSHOT_ENABLED=false

# Logging functions for Duplicati integration
# Messages with these prefixes appear in Duplicati logs
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

# Handle fluxcd mode - fail fast
if [ "$RECONCILE_MODE" = "fluxcd" ]; then
  log_error "FluxCD reconciliation mode is not yet implemented. Please use 'argocd' or 'snapshot' mode instead."
  exit 1
fi

# Setup snapshot mode
if [ "$RECONCILE_MODE" = "snapshot" ]; then
  SNAPSHOT_ENABLED=true
  log_info "Snapshot mode enabled - recording replica counts before scaling down"

  # Create snapshot directory
  mkdir -p "$SNAPSHOT_DIR"

  # Create unique snapshot file
  SNAPSHOT_FILE="$SNAPSHOT_DIR/snapshot-$(date +%Y%m%d%H%M%S)-$$.json"

  # Verify directory is writable (don't initialize file - it will be created on first write)
  if [ ! -w "$SNAPSHOT_DIR" ]; then
    log_error "Snapshot directory is not writable: $SNAPSHOT_DIR"
    exit 1
  fi

  log_info "Recording snapshot to: $SNAPSHOT_FILE"
fi

# Function to record a scale operation to the snapshot
# Usage: record_scale <kind> <namespace> <name> <replicas>
record_scale() {
  if [ "$SNAPSHOT_ENABLED" = true ]; then
    local kind="$1"
    local namespace="$2"
    local name="$3"
    local replicas="$4"

    jq -n -c \
      --arg kind "$kind" \
      --arg namespace "$namespace" \
      --arg name "$name" \
      --argjson replicas "$replicas" \
      '{"kind": $kind, "namespace": $namespace, "name": $name, "replicas": $replicas}' >> "$SNAPSHOT_FILE"
  fi
}

log_info "Starting pre-backup script..."

# Step 1: Scale down ArgoCD deployments and statefulsets
# This prevents ArgoCD from reconciling any changes to applications
# TODO: Implement proper ArgoCD app pause/resume via CLI or API
log_info "Scaling down ArgoCD deployments..."

# Scale down Deployments
argocd_deployments=$(k3s kubectl get deployments -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for deployment in $argocd_deployments; do
  if [ -n "$deployment" ]; then
    # Get current replicas (default to 1 if not specified)
    current_replicas=$(k3s kubectl get deployment "$deployment" -n argocd -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    current_replicas=${current_replicas:-1}
    record_scale "deployment" "argocd" "$deployment" "$current_replicas"
    log_info "Scaling down deployment: argocd/$deployment (replicas: $current_replicas -> 0)"
    k3s kubectl scale deployment "$deployment" -n argocd --replicas=0 2>/dev/null || true
  fi
done

# Scale down StatefulSets
argocd_statefulsets=$(k3s kubectl get statefulsets -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for statefulset in $argocd_statefulsets; do
  if [ -n "$statefulset" ]; then
    # Get current replicas (default to 1 if not specified)
    current_replicas=$(k3s kubectl get statefulset "$statefulset" -n argocd -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    current_replicas=${current_replicas:-1}
    record_scale "statefulset" "argocd" "$statefulset" "$current_replicas"
    log_info "Scaling down statefulset: argocd/$statefulset (replicas: $current_replicas -> 0)"
    k3s kubectl scale statefulset "$statefulset" -n argocd --replicas=0 2>/dev/null || true
  fi
done

# Wait for ArgoCD pods to terminate
log_info "Waiting for ArgoCD pods to terminate..."
timeout 120 k3s kubectl wait --for=delete pods -n argocd --all --timeout=120s 2>/dev/null || true

# Step 2: Scale down deployments using PVCs
# Query PVCs from Kubernetes API to get correct PVC names
log_info "Scaling down deployments using PVCs..."

# Get all PVCs that are using the configured storage class
pvc_list=$(k3s kubectl get pvc -A -o json 2>/dev/null | jq -r "
  .items[] |
  select(.spec.storageClassName == \"$STORAGE_CLASS\") |
  \"\(.metadata.namespace) \(.metadata.name)\"
" || true)

if [ -n "$pvc_list" ]; then
  scaled_count=0

  while read -r pvc_namespace pvc_name; do
    [ -z "$pvc_namespace" ] && continue
    [ -z "$pvc_name" ] && continue

    # Skip argocd namespace PVCs (already handled above)
    [ "$pvc_namespace" = "argocd" ] && continue

    # Find deployments using this PVC (match both name and namespace)
    deployments=$(k3s kubectl get deployments -A -o json 2>/dev/null | jq -r "
      .items[] |
      select(.metadata.namespace == \"$pvc_namespace\" and
             .spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\") |
      \"\(.metadata.namespace) \(.metadata.name)\"
    " || true)

    if [ -n "$deployments" ]; then
      while read -r namespace name; do
        [ -z "$namespace" ] && continue
        [ -z "$name" ] && continue

        # Get current replicas (default to 1 if not specified)
        current_replicas=$(k3s kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        current_replicas=${current_replicas:-1}
        record_scale "deployment" "$namespace" "$name" "$current_replicas"
        log_info "Scaling down: $namespace/$name (replicas: $current_replicas -> 0)"
        if timeout 60 k3s kubectl scale deployment "$name" -n "$namespace" --replicas=0 2>/dev/null; then
          scaled_count=$((scaled_count + 1))

          # Wait for pods to terminate (with timeout)
          timeout 120 k3s kubectl wait --for=delete pods \
            -l "app.kubernetes.io/instance=$name" \
            -n "$namespace" --timeout=120s 2>/dev/null || true
        else
          log_error "Failed to scale down: $namespace/$name"
        fi
      done <<< "$deployments"
    fi
  done <<< "$pvc_list"

  log_info "Scaled down $scaled_count deployments"
else
  log_info "No PVCs found with $STORAGE_CLASS storage class"
fi

log_info "Pre-backup script completed successfully"
exit 0
