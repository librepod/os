# Legacy Single Backup Strategy for Duplicati
#
# This module backs up all PVCs in a single Duplicati backup job.
#
# WARNING: This approach has a significant limitation:
# Restoring one PVC requires restoring ALL PVCs, causing data loss
# for healthy services (data since last backup is lost).
#
# Consider using the per-PVC backup strategy (per-pvc.nix) instead,
# which enables granular restore of individual PVCs.
#
# Backup structure:
#   Source: /exports/k3s/
#   Target: /media/USB DISK/librepod-backups/
#
# This module is preserved for:
#   - Backward compatibility with existing backups
#   - Scenarios where single-backup approach is preferred
#   - Reference and rollback capability

{ config, pkgs, lib, ... }:

let
  cfg = config.services.duplicati;

  # Pre/post backup scripts (imported from main module)
  preBackupScript = pkgs.writeShellApplication {
    name = "duplicati-pre-backup";
    runtimeInputs = with pkgs; [ k3s argocd jq coreutils ];
    text = ''
      export DUPLICATI_POST_BACKUP_RECONCILE="${cfg.k3sPostBackupReconcile}"
      export DUPLICATI_SCALE_SNAPSHOT_DIR="/var/lib/duplicati/scale-snapshots"
      ${builtins.readFile ./scripts/pre-backup.sh}
    '';
  };

  postBackupScript = pkgs.writeShellApplication {
    name = "duplicati-post-backup";
    runtimeInputs = with pkgs; [ k3s argocd jq coreutils ];
    text = ''
      export DUPLICATI_POST_BACKUP_RECONCILE="${cfg.k3sPostBackupReconcile}"
      export DUPLICATI_SCALE_SNAPSHOT_DIR="/var/lib/duplicati/scale-snapshots"
      ${builtins.readFile ./scripts/post-backup.sh}
    '';
  };

  # Backup configuration
  backupName = "k3s-data";
  backupSource = "/exports/k3s/";
  backupTarget = "file:///media/USB DISK/librepod-backups/";
  backupDbPath = "/var/lib/duplicati/k3s-data.sqlite";
  schedule = "*-*-* 03:15:00";  # Daily at 3:15 AM
  retentionPolicy = "1W:1D,4W:1W,12M:1M";
  dblockSize = "50mb";

  # Wrapper script that sets up the environment for duplicati-cli
  # Duplicati is a .NET application that needs ICU libraries for globalization support
  duplicatiBackupWrapper = pkgs.writeShellApplication {
    name = "duplicati-backup-wrapper";
    runtimeInputs = with pkgs; [ k3s argocd jq coreutils duplicati icu ];
    text = ''
      # Set DOTNET_SYSTEM_GLOBALIZATION_INVARIANT to work around ICU issues on NixOS
      # This disables globalization support but allows Duplicati to run
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

      # Run the duplicati-cli command with all parameters
      exec ${pkgs.duplicati}/bin/duplicati-cli backup \
        "${backupTarget}" \
        "${backupSource}" \
        --backup-name="${backupName}" \
        --dbpath="${backupDbPath}" \
        --backup-id="k3s-data-backup" \
        --compression-module=zip \
        --dblock-size=${dblockSize} \
        --retention-policy="${retentionPolicy}" \
        --no-encryption \
        --run-script-before-required=/run/current-system/sw/bin/duplicati-pre-backup \
        --run-script-after=/run/current-system/sw/bin/duplicati-post-backup \
        --disable-module=console-password-input
    '';
  };
in
{
  # Make backup scripts available system-wide
  environment.systemPackages = [ preBackupScript postBackupScript ];

  # Single Backup Service (Legacy)
  # ===========================================
  # Backs up all PVCs in a single Duplicati backup job.
  #
  # NOTE: Consider using per-PVC backup strategy instead for granular restore.

  systemd.services.duplicati-backup-k3s = {
    description = "Duplicati backup job for k3s data (legacy - all PVCs combined)";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Use the wrapper script which handles environment and dependencies
      ExecStart = "${duplicatiBackupWrapper}/bin/duplicati-backup-wrapper";
      # Ensure backup directory exists
      WorkingDirectory = "/var/lib/duplicati";
      # Security hardening
      ReadOnlyPaths = [ backupSource ];
      # Standard output logging
      StandardOutput = "journal";
      StandardError = "journal";
      # INFO: Accept Duplicati's non-zero exit codes as success
      #
      # Duplicati uses exit codes to communicate backup state, not just success/failure.
      # Without this directive, systemd treats any non-zero exit as failure.
      #
      # Duplicati exit codes (from "duplicati-cli help returncodes"):
      #   0 - Success (files changed in backup)
      #   1 - Successful operation, but no files were changed
      #   2 - Successful operation, but with warning(s)
      #   3 - For backup: finished with error(s)
      #  50 - Backup uploaded some files, but did not finish
      # 100 - An error occurred
      # 200 - Invalid commandline arguments found
      #
      # We accept exit codes 0, 1, and 2 as successful backups.
      # Exit code 1 is common when running frequent backups (no new changes to backup).
      # Exit code 2 occurs when there are non-fatal warnings (e.g., SQLite warnings).
      SuccessExitStatus = [ 1 2 ];
    };
    # Only run if k3s is running
    wants = [ "k3s.service" ];
    after = [ "k3s.service" "network-online.target" ];
  };

  # Systemd timer for nightly backups
  systemd.timers.duplicati-backup-k3s = {
    description = "Timer for Duplicati k3s data backup (legacy)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = schedule;
      Persistent = true;  # Run immediately if last backup was missed (e.g., system off)
      Unit = "duplicati-backup-k3s.service";
    };
  };
}
