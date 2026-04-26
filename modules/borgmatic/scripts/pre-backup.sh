set -euo pipefail

# Pre-backup script with FluxCD integration
#
# This script prepares the cluster for a consistent backup by:
# 1. Suspending FluxCD Kustomization reconciliation
# 2. Suspending HelmReleases (independent controller from Kustomizations)
# 3. Scaling down deployments that use PVCs
# 4. Waiting for pods to terminate
#
# After backup completes, the post-backup script resumes Flux reconciliation,
# which restores all workloads to their desired Git state.

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STORAGE_CLASS=nfs-client

# Logging functions
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting pre-backup script..."

# Step 1: Suspend FluxCD Kustomizations
# This prevents Flux from re-creating pods we're about to scale down
log_info "Suspending FluxCD Kustomizations..."
flux suspend kustomization --all --namespace flux-system || {
  log_error "Failed to suspend FluxCD Kustomizations"
  exit 1
}
log_info "FluxCD Kustomizations suspended"

# Step 2: Suspend HelmReleases
# HelmRelease controller runs independently of Kustomizations.
# We must suspend them too, otherwise they may re-create pods we scale down in step 3.
log_info "Suspending HelmReleases..."
hr_list=$(k3s kubectl get helmrelease -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ -n "$hr_list" ]; then
  hr_count=0
  while read -r hr; do
    hr_namespace="${hr%%/*}"
    hr_name="${hr##*/}"
    [ -z "$hr_namespace" ] || [ -z "$hr_name" ] && continue

    log_info "Suspending HelmRelease: $hr_namespace/$hr_name"
    flux suspend helmrelease "$hr_name" --namespace "$hr_namespace" 2>/dev/null || {
      log_error "Failed to suspend HelmRelease: $hr_namespace/$hr_name"
    }
    hr_count=$((hr_count + 1))
  done <<< "$hr_list"
  log_info "Suspended $hr_count HelmReleases"
else
  log_info "No HelmReleases found"
fi

# Step 3: Scale down deployments using PVCs
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

        log_info "Scaling down: $namespace/$name (replicas -> 0)"
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
