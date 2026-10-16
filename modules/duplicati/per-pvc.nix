# Per-PVC Backup Strategy for Duplicati
#
# This module creates a separate Duplicati backup for each Kubernetes PVC.
# This enables granular restore of individual PVCs without affecting other PVCs.
#
# Backup structure:
#   Source: /exports/k3s/<namespace>/<pvc-name>/
#   Target: /media/USB DISK/librepod-backups/k3s/<namespace>/<pvc-name>/
#
# The backup directory structure mirrors the source structure for easy navigation.
#
# Benefits:
#   - Restore single PVC without overwriting others
#   - No data loss for healthy services during restore
#   - Automatic discovery of new PVCs (no config changes needed)
#   - Intuitive directory structure matching source layout
#
# To restore a specific PVC:
#   duplicati-cli restore "file:///media/USB DISK/librepod-backups/k3s/<namespace>/<pvc-name>/" \
#     /exports/k3s/<namespace>/<pvc-name>/ --restore-path=*

{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Shared pre/post-backup hooks + boot recovery unit (issue #12), built for
  # this tool by modules/common/backup-hooks.
  backupHooks = import ../common/backup-hooks {
    inherit pkgs;
    toolName = "duplicati";
    stateFilePath = "/var/lib/duplicati/scaled-deployments.txt";
    backupUnitName = "duplicati-backup-k3s-per-pvc.service";
  };

  inherit (backupHooks)
    preBackupScript
    postBackupScript
    ;

  # Per-PVC backup script
  # Discovers all PVCs in Kubernetes and creates a separate backup for each one
  perPvcBackupScript = pkgs.writeShellApplication {
    name = "duplicati-backup-per-pvc";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      jq
      coreutils
      duplicati
      icu
    ];
    text = builtins.readFile ./scripts/backup-per-pvc.sh;
  };

  # Backup schedule
  schedule = "*-*-* 03:15:00"; # Daily at 3:15 AM
in
{
  # Make backup scripts available system-wide
  environment.systemPackages = [
    preBackupScript
    postBackupScript
    perPvcBackupScript
  ];

  # Per-PVC Backup Service
  # ===========================================
  # Discovers all PVCs and creates a separate Duplicati backup for each.
  # This enables granular restore of individual PVCs without affecting others.

  systemd.services.duplicati-backup-k3s-per-pvc = {
    description = "Duplicati per-PVC backup job for k3s data";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Use the per-PVC backup script which handles PVC discovery and backup
      ExecStart = "${perPvcBackupScript}/bin/duplicati-backup-per-pvc";
      # Ensure backup directory exists
      WorkingDirectory = "/var/lib/duplicati";
      # Security hardening - allow read access to all PVCs
      ReadOnlyPaths = [ "/exports/k3s" ];
      # Standard output logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
    # Only run if k3s is running and network is available
    wants = [
      "k3s.service"
      "network-online.target"
    ];
    after = [
      "k3s.service"
      "network-online.target"
      # Pure ordering (no wants): serialize with boot recovery in case the
      # Persistent timer fires a catch-up backup while recovery is restoring.
      "duplicati-recovery.service"
    ];
  };

  # Boot-time recovery from a reboot during the backup window (issue #12):
  # a surviving state file means a backup was interrupted mid-run — the fleet
  # is at 0 replicas with Flux suspended. The shared recovery unit reruns
  # post-backup (guarding against a mid-backup `nixos-rebuild switch`) and
  # retries until the restore fully succeeds.
  systemd.services.duplicati-recovery = backupHooks.recoveryService;

  # Systemd timer for nightly per-PVC backups
  systemd.timers.duplicati-backup-k3s-per-pvc = {
    description = "Timer for Duplicati per-PVC k3s backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = schedule;
      Persistent = true; # Run immediately if last backup was missed (e.g., system off)
      Unit = "duplicati-backup-k3s-per-pvc.service";
    };
  };
}
