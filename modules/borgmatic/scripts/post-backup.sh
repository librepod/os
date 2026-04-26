set -euo pipefail

# Post-backup script with FluxCD integration
#
# This script restores all workloads after backup completes:
# 1. Resumes FluxCD Kustomizations (restores plain-kustomize deployments)
# 2. Resumes HelmReleases (removes suspend flag)
# 3. Force-reconciles HelmReleases (forces Helm upgrade to restore replicas)
#
# Step 3 is necessary because Helm's three-way merge preserves externally-modified
# fields (like replicas scaled to 0) when the chart values haven't changed.
# Force reconcile bypasses this and re-applies the chart template defaults.

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting post-backup script..."

# Step 1: Resume FluxCD Kustomizations
# flux resume marks resources for reconciliation and waits for the apply to finish.
# This restores deployments managed directly by Kustomize (not via HelmRelease).
log_info "Resuming FluxCD Kustomizations..."
flux resume kustomization --all --namespace flux-system || {
  log_error "Failed to resume FluxCD Kustomizations"
  exit 1
}
log_info "FluxCD Kustomizations resumed and reconciled"

# Step 2: Resume HelmReleases
# Remove the suspend flag so the HelmRelease controller resumes reconciliation.
# The regular reconciliation alone does NOT restore scaled-down replicas because
# Helm's three-way merge preserves external changes when chart values are unchanged.
log_info "Resuming HelmReleases..."
hr_list=$(k3s kubectl get helmrelease -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ -n "$hr_list" ]; then
  hr_count=0
  while read -r hr; do
    hr_namespace="${hr%%/*}"
    hr_name="${hr##*/}"
    [ -z "$hr_namespace" ] || [ -z "$hr_name" ] && continue

    log_info "Resuming HelmRelease: $hr_namespace/$hr_name"
    flux resume helmrelease "$hr_name" --namespace "$hr_namespace" || {
      log_error "Failed to resume HelmRelease: $hr_namespace/$hr_name"
    }
    hr_count=$((hr_count + 1))
  done <<< "$hr_list"
  log_info "Resumed $hr_count HelmReleases"
else
  log_info "No HelmReleases found"
fi

# Step 3: Force-reconcile HelmReleases
# Forces a Helm upgrade that re-applies chart templates, overwriting any
# externally-modified fields (like replicas scaled to 0 during backup).
log_info "Force-reconciling HelmReleases to restore scaled-down deployments..."
if [ -n "$hr_list" ]; then
  while read -r hr; do
    hr_namespace="${hr%%/*}"
    hr_name="${hr##*/}"
    [ -z "$hr_namespace" ] || [ -z "$hr_name" ] && continue

    log_info "Force-reconciling HelmRelease: $hr_namespace/$hr_name"
    flux reconcile helmrelease "$hr_name" --namespace "$hr_namespace" --force || {
      log_error "Failed to force-reconcile HelmRelease: $hr_namespace/$hr_name"
    }
  done <<< "$hr_list"
fi

log_info "HelmReleases force-reconciled"
log_info "Post-backup script completed successfully"
exit 0
