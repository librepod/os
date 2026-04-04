#!/usr/bin/env bash
# Per-PVC Backup Script for Duplicati
#
# This script discovers all PVCs in the Kubernetes cluster and creates a separate
# Duplicati backup for each PVC. This enables granular restore of individual PVCs
# without affecting other PVCs' data.
#
# Backup structure:
#   Source: /exports/k3s/<namespace>/<pvc-name>/
#   Target: /media/USB DISK/librepod-backups/k3s/<namespace>/<pvc-name>/
#
# The backup directory structure mirrors the source structure for easy navigation.
#
# Usage: Called by systemd timer (no arguments required)

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Kubernetes configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STORAGE_CLASS="nfs-client"
BACKUP_SOURCE_BASE="/exports/k3s"
BACKUP_TARGET_BASE="file:///media/USB DISK/librepod-backups/k3s"
BACKUP_DB_BASE="/var/lib/duplicati"

# Duplicati settings
DBLOCK_SIZE="50mb"
RETENTION_POLICY="1W:1D,4W:1W,12M:1M"
ENCRYPTION="--no-encryption"
COMPRESSION_MODULE="zip"

# Pre/post backup scripts (absolute paths)
PRE_BACKUP_SCRIPT="/run/current-system/sw/bin/duplicati-pre-backup"
POST_BACKUP_SCRIPT="/run/current-system/sw/bin/duplicati-post-backup"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_success() {
  echo "LOG:INFO ✓ $*"
}

log_warning() {
  echo "LOG:WARNING ⚠ $*"
}

# ============================================================================
# MAIN BACKUP LOGIC
# ============================================================================

log_info "=========================================="
log_info "Starting per-PVC backup process..."
log_info "=========================================="

# Discover all PVCs using the configured storage class
log_info "Discovering PVCs with storage class: $STORAGE_CLASS"

pvc_list=$(k3s kubectl get pvc -A -o json 2>/dev/null | jq -r "
  .items[] |
  select(.spec.storageClassName == \"$STORAGE_CLASS\") |
  \"\(.metadata.namespace) \(.metadata.name)\"
" || true)

if [ -z "$pvc_list" ]; then
  log_warning "No PVCs found with storage class: $STORAGE_CLASS"
  log_info "Backup completed successfully (0 PVCs to backup)"
  exit 0
fi

# Count PVCs
pvc_count=$(echo "$pvc_list" | wc -l)
log_info "Found $pvc_count PVC(s) to backup"

# Set up environment for Duplicati (.NET ICU workaround)
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# Track statistics
declare -i backup_success=0
declare -i backup_failed=0
declare -i backup_skipped=0
declare -i backup_no_changes=0

# Run pre-backup script (scales down deployments)
if [ -x "$PRE_BACKUP_SCRIPT" ]; then
  log_info "Running pre-backup script..."
  if "$PRE_BACKUP_SCRIPT"; then
    log_success "Pre-backup script completed"
  else
    log_error "Pre-backup script failed (exit code $?)"
    exit 1  # Pre-backup failure is critical - don't proceed
  fi
else
  log_warning "Pre-backup script not found or not executable: $PRE_BACKUP_SCRIPT"
fi

# Backup each PVC
log_info "=========================================="
log_info "Backing up individual PVCs..."
log_info "=========================================="

while read -r pvc_namespace pvc_name; do
  [ -z "$pvc_namespace" ] && continue
  [ -z "$pvc_name" ] && continue

  # Create backup identifier (hyphenated for filesystem compatibility)
  # Used for backup name and database file naming
  backup_id="${pvc_namespace}-${pvc_name}"
  log_info "------------------------------------------"
  log_info "Processing PVC: $pvc_namespace/$pvc_name"
  log_info "Backup ID: $backup_id"

  # Define paths for this PVC
  # Source and target paths mirror each other for easy navigation
  backup_source="$BACKUP_SOURCE_BASE/$pvc_namespace/$pvc_name"
  backup_target="$BACKUP_TARGET_BASE/$pvc_namespace/$pvc_name/"
  backup_db_path="$BACKUP_DB_BASE/$backup_id.sqlite"

  # Check if source directory exists
  if [ ! -d "$backup_source" ]; then
    log_warning "Source directory not found: $backup_source"
    log_warning "Skipping PVC: $backup_id (no local data yet)"
    backup_skipped=$((backup_skipped + 1))

    # Create empty backup for future use (Duplicati will handle this)
    # This ensures backup is ready when PVC gets data
    log_info "Creating placeholder backup for: $backup_id"
  else
    log_info "Source: $backup_source"
    log_info "Target: $backup_target"
    log_info "Database: $backup_db_path"
  fi

  # Ensure backup target directory structure exists
  # Convert file:// URI path to filesystem path for mkdir
  backup_target_dir="${backup_target#file://}"
  backup_target_dir="${backup_target_dir%/}"  # Remove trailing slash
  if [ ! -d "$backup_target_dir" ]; then
    log_info "Creating backup target directory: $backup_target_dir"
    mkdir -p "$backup_target_dir"
  fi

  # Ensure backup database directory exists
  backup_db_dir=$(dirname "$backup_db_path")
  if [ ! -d "$backup_db_dir" ]; then
    mkdir -p "$backup_db_dir"
  fi

  # Run Duplicati backup for this PVC
  log_info "Starting Duplicati backup: $backup_id"

  # Duplicati exit codes:
  #   0 - Success (files changed in backup)
  #   1 - Successful operation, but no files were changed
  #   2 - Successful operation, but with warning(s)
  #   3+ - Error occurred
  duplicati_exit_code=0

  if duplicati-cli backup \
    "$backup_target" \
    "$backup_source" \
    --backup-name="$backup_id" \
    --backup-id="k3s-pvc-$backup_id" \
    --dbpath="$backup_db_path" \
    --compression-module="$COMPRESSION_MODULE" \
    --dblock-size="$DBLOCK_SIZE" \
    --retention-policy="$RETENTION_POLICY" \
    $ENCRYPTION \
    --disable-module=console-password-input \
    2>&1; then
    duplicati_exit_code=$?
  else
    duplicati_exit_code=$?
  fi

  # Interpret Duplicati exit code
  case $duplicati_exit_code in
    0)
      log_success "Backup completed: $backup_id (files changed)"
      backup_success=$((backup_success + 1))
      ;;
    1)
      log_success "Backup completed: $backup_id (no changes)"
      backup_no_changes=$((backup_no_changes + 1))
      ;;
    2)
      log_success "Backup completed: $backup_id (with warnings)"
      backup_success=$((backup_success + 1))
      ;;
    *)
      log_error "Backup FAILED: $backup_id (exit code: $duplicati_exit_code)"
      backup_failed=$((backup_failed + 1))
      ;;
  esac

done <<< "$pvc_list"

# Run post-backup script (scales up deployments)
if [ -x "$POST_BACKUP_SCRIPT" ]; then
  log_info "=========================================="
  log_info "Running post-backup script..."
  if "$POST_BACKUP_SCRIPT"; then
    log_success "Post-backup script completed"
  else
    log_error "Post-backup script failed (exit code $?)"
    # Continue anyway - backup is complete
  fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

log_info "=========================================="
log_info "Backup Summary"
log_info "=========================================="
log_info "Total PVCs discovered: $pvc_count"
log_info "Successful backups:    $backup_success"
log_info "No changes:             $backup_no_changes"
log_info "Skipped (no data):      $backup_skipped"
log_info "Failed:                 $backup_failed"
log_info "=========================================="

if [ $backup_failed -gt 0 ]; then
  log_error "Backup completed with errors"
  exit 1
else
  log_info "Backup completed successfully"
  exit 0
fi
