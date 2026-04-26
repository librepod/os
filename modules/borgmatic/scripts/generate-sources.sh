set -euo pipefail

# Dynamic source directory generator for borgmatic
#
# Queries Kubernetes for all PVCs (excluding those labeled
# backup.librepod.dev/disabled=true) and resolves their NFS filesystem paths
# via the bound PV's spec.nfs.path.
# Generates /run/borgmatic/sources.yaml with a source_directories list
# that borgmatic includes via <<: !include in its base config.
#
# Graceful handling:
#   - k3s not running      → empty source_directories (backup is no-op)
#   - PVC with no bound PV → skipped (not yet provisioned)

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STORAGE_CLASS=nfs-client
SKIP_LABEL=backup.librepod.dev/disabled
OUTPUT_FILE=/run/borgmatic/sources.yaml

# Logging functions
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Generating dynamic backup source list..."

# Query all PVCs with matching storage class, excluding those with the skip label
# Output format: namespace pvc_name volume_name (one per line)
pvc_list=$(k3s kubectl get pvc -A -o json 2>/dev/null | jq -r '
  .items[] |
  select(.spec.storageClassName == "'"$STORAGE_CLASS"'") |
  select((.metadata.labels["'"$SKIP_LABEL"'"] // "") != "true") |
  "\(.metadata.namespace) \(.metadata.name) \(.spec.volumeName // "")"
' 2>/dev/null || true)

sources=()

if [ -n "$pvc_list" ]; then
  while read -r namespace pvc_name pv_name; do
    [ -z "$namespace" ] && continue
    [ -z "$pvc_name" ] && continue
    [ -z "$pv_name" ] && continue

    # Resolve the NFS filesystem path from the bound PV
    nfs_path=$(k3s kubectl get pv "$pv_name" -o jsonpath='{.spec.nfs.path}' 2>/dev/null || true)

    if [ -n "$nfs_path" ]; then
      log_info "Including PVC $namespace/$pvc_name -> $nfs_path"
      sources+=("$nfs_path")
    else
      log_error "Could not resolve NFS path for PV $pv_name (PVC $namespace/$pvc_name), skipping"
    fi
  done <<< "$pvc_list"
fi

# Generate the borgmatic source_directories config file
if [ ${#sources[@]} -eq 0 ]; then
  log_info "No PVCs available for backup, generating empty source_directories"
  printf 'source_directories: []\n' > "$OUTPUT_FILE"
else
  log_info "Generated source list with ${#sources[@]} PVC paths"
  printf 'source_directories:\n' > "$OUTPUT_FILE"
  for path in "${sources[@]}"; do
    printf '  - "%s"\n' "$path" >> "$OUTPUT_FILE"
  done
fi

log_info "Source list written to $OUTPUT_FILE"
exit 0
