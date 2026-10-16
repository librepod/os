set -euo pipefail

# Shared pre-backup hook (used by the borgmatic and duplicati modules):
# suspend Flux, scale PVC-backed deployments to 0 recording replica counts,
# wait for termination. Post-backup restores the fleet to its Git state.

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

# State file (WAL rule, issue #12): persistent, never tmpfs. Written before
# scale-down; never truncated (a leftover file = an aborted run whose counts
# are the only record of desired replica counts — restore from it first);
# consumed by post-backup only after a fully successful restore. Substituted
# from modules/common/backup-hooks, the single source of truth.
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

          # Wait for the scale-down to complete before the backup reads the PVC.
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
