set -euo pipefail

# Post-backup script for Duplicati with FluxCD integration
#
# This script resumes FluxCD Kustomization reconciliation after backup completes.
# Flux will detect any drift between Git state and cluster state, and restore
# all workloads to their desired replica counts.

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions for Duplicati integration
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting post-backup script..."

# Resume FluxCD Kustomizations
# flux resume marks resources for reconciliation and waits for the apply to finish
log_info "Resuming FluxCD Kustomizations..."
flux resume kustomization --all --namespace flux-system || {
  log_error "Failed to resume FluxCD Kustomizations"
  exit 1
}

log_info "FluxCD Kustomizations resumed and reconciled"
log_info "Post-backup script completed successfully"
exit 0
