set -euo pipefail

# Post-backup script with FluxCD integration
#
# This script restores all workloads after backup completes:
# 1. Resumes and force-reconciles HelmReleases (restores scaled-down deployments)
# 2. Resumes FluxCD Kustomizations (re-applies all resources including Jobs)
#
# HelmReleases MUST be resumed before Kustomizations to break a circular
# dependency caused by Kubernetes server-side apply (SSA) field ownership:
#
#   The pre-backup script sets spec.suspend=true on HelmReleases via the
#   `flux` CLI field manager. When the kustomize-controller later reapplies
#   the HelmRelease from the OCI artifact source, it uses SSA with its own
#   field manager ("kustomize-controller"). Since the source YAML does not
#   include spec.suspend, SSA does not touch that field — it remains owned
#   by the "flux" manager and stays true. The HelmRelease stays suspended.
#
#   If Kustomizations were resumed first, any bootstrap Jobs (e.g.
#   job-step-ca-bootstrap-resources) would start polling for services
#   deployed by those HelmReleases. But the HelmReleases are still suspended,
#   so the services never come up. The Job fails, the Kustomization fails,
#   and `flux resume kustomization --all --wait` returns an error — which
#   exits the post-backup script before HelmReleases are ever resumed.
#
#   By resuming HelmReleases first:
#     1. The helm-controller can reconcile and deploy workloads immediately
#     2. Force-reconcile restores Deployments scaled to 0 by pre-backup
#     3. When Kustomizations resume, bootstrap Jobs find healthy services

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

# Step 1: Resume and force-reconcile HelmReleases
#
# Resume removes the suspend flag so the helm-controller can reconcile.
# Force-reconcile triggers a Helm upgrade that re-applies chart templates,
# overwriting externally-modified fields (like replicas scaled to 0 during
# backup). Without --force, Helm's three-way merge preserves the scaled-down
# replicas because the chart values haven't changed.
log_info "Resuming and force-reconciling HelmReleases..."
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
      continue
    }

    log_info "Force-reconciling HelmRelease: $hr_namespace/$hr_name"
    flux reconcile helmrelease "$hr_name" --namespace "$hr_namespace" --force || {
      log_error "Failed to force-reconcile HelmRelease: $hr_namespace/$hr_name"
    }
    hr_count=$((hr_count + 1))
  done <<< "$hr_list"
  log_info "Resumed and force-reconciled $hr_count HelmReleases"
else
  log_info "No HelmReleases found"
fi

# Step 2: Resume FluxCD Kustomizations
#
# Now that HelmReleases are restored, Kustomization reconciliation can
# succeed. flux resume marks resources for reconciliation and waits for the
# apply to finish. Bootstrap Jobs will find healthy services and complete.
log_info "Resuming FluxCD Kustomizations..."
flux resume kustomization --all --namespace flux-system || {
  log_error "Failed to resume FluxCD Kustomizations"
  exit 1
}
log_info "FluxCD Kustomizations resumed and reconciled"

log_info "Post-backup script completed successfully"
exit 0
