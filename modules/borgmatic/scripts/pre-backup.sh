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
SKIP_LABEL=backup.libre.pod/disabled

# Logging functions
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

# Replica-count state file. @STATE_FILE@ is substituted from default.nix —
# the single source of truth, shared with borgmatic-recovery.service's
# ConditionPathExists. Must live on persistent storage, NOT tmpfs: a reboot
# mid-backup wipes /run, orphaning the fleet at 0 replicas with Flux
# suspended (issue #12).
#
# A leftover file means the previous run ended without a successful restore
# (reboot, SIGKILL, OOM, systemctl stop). Its replica counts are the only
# record of the fleet's desired size — never truncate them: re-capturing
# spec.replicas now would record 0 for every scaled-down deployment and
# poison every later restore. Restore the fleet first, then record fresh
# counts below as we scale down again.
STATE_FILE="@STATE_FILE@"
mkdir -p "$(dirname "$STATE_FILE")"
if [ -f "$STATE_FILE" ]; then
  log_info "Leftover state file — previous run never restored; restoring fleet before scaling down again"
  "@POST_BACKUP@" || {
    log_error "Restore from aborted run failed; aborting this backup run"
    exit 1
  }
fi

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

# Get PVCs using the configured storage class, excluding those with the skip label.
# Only deployments using these PVCs are scaled down — skipped apps stay running.
pvc_list=$(k3s kubectl get pvc -A -o json 2>/dev/null | jq -r "
  .items[] |
  select(.spec.storageClassName == \"$STORAGE_CLASS\") |
  select((.metadata.labels[\"$SKIP_LABEL\"] // \"\") != \"true\") |
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

        # Save current replica count for post-backup restore.
        # Helm's three-way merge treats scale-down as an intentional external
        # change and preserves it on upgrade, so we must restore explicitly.
        replicas=$(k3s kubectl get deployment "$name" -n "$namespace" \
          -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

        if ! [[ "$replicas" =~ ^[0-9]+$ ]] || [ "$replicas" -lt 1 ]; then
          # Already at 0 (or unknown): nothing to save. Recording 0 here is
          # exactly how an aborted run poisons the state file.
          log_info "Skipping $namespace/$name: replicas=$replicas (already down or unknown)"
          continue
        fi

        log_info "Scaling down: $namespace/$name (replicas $replicas -> 0)"
        if timeout 60 k3s kubectl scale deployment "$name" -n "$namespace" --replicas=0 2>/dev/null; then
          echo "$namespace $name $replicas" >> "$STATE_FILE"
          scaled_count=$((scaled_count + 1))

          # Wait for the scale-down to complete before borg reads the PVC.
          # rollout status succeeds once the deployment reports 0/0 — a
          # label-based pod wait silently matches nothing when pods lack
          # app.kubernetes.io/instance=<deployment name>.
          k3s kubectl rollout status deployment "$name" -n "$namespace" \
            --timeout=120s 2>/dev/null || true
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
