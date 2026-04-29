set -euo pipefail

# Post-backup script for Duplicati with FluxCD integration
#
# This script restores all workloads after backup completes:
# 1. Resumes HelmReleases (removes suspend flag)
# 2. Restores scaled-down deployments (explicit kubectl scale)
# 3. Resumes FluxCD Kustomizations (re-applies all resources including Jobs)
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
#     2. Explicit kubectl scale restores Deployments (Helm won't)
#     3. When Kustomizations resume, bootstrap Jobs find healthy services

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions for Duplicati integration
# Messages with these prefixes appear in Duplicati logs
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting post-backup script..."

# Step 1: Resume HelmReleases (just remove the suspend flag, no waiting)
#
# We resume HelmReleases without waiting so we can proceed to scale-up
# quickly. The HelmReleases will reconcile asynchronously.
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

# Step 2: Restore scaled-down deployments
#
# Helm's three-way strategic merge treats external scale-down as an
# intentional change and preserves it on upgrade (even with --force).
# We must restore replicas explicitly from the state file written by
# the pre-backup script. Without this, deployments stay at replicas=0
# indefinitely.
log_info "Restoring scaled-down deployments..."
state_file=/run/duplicati/scaled-deployments.txt
if [ -f "$state_file" ]; then
  restore_count=0
  while read -r namespace name replicas; do
    [ -z "$namespace" ] || [ -z "$name" ] || [ -z "$replicas" ] && continue

    log_info "Scaling up: $namespace/$name (replicas -> $replicas)"
    k3s kubectl scale deployment "$name" -n "$namespace" --replicas="$replicas" 2>/dev/null || {
      log_error "Failed to scale up: $namespace/$name"
      continue
    }
    restore_count=$((restore_count + 1))
  done < "$state_file"
  log_info "Restored $restore_count deployments"
  rm -f "$state_file"
else
  log_info "No scaled-deployments state file found — nothing to restore"
fi

# Step 3: Resume FluxCD Kustomizations
#
# Now that deployments are restored and HelmReleases are unsuspended,
# Kustomization reconciliation can succeed. flux resume waits for the
# apply to finish. Bootstrap Jobs will find healthy services and complete.
log_info "Resuming FluxCD Kustomizations..."
flux resume kustomization --all --namespace flux-system || {
  log_error "Failed to resume FluxCD Kustomizations"
  exit 1
}
log_info "FluxCD Kustomizations resumed and reconciled"

log_info "Post-backup script completed successfully"
exit 0
