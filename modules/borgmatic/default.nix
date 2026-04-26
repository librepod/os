# Borgmatic backup module with FluxCD integration
#
# This module configures borgmatic for automated nightly backups of k3s PVC data.
# Borg's content-addressed storage enables per-PVC restore via path-based extraction
# without requiring separate backup jobs per PVC.
#
# Pre/post backup hooks suspend/resume FluxCD Kustomizations and HelmReleases,
# then scale K8s deployments for consistent snapshots.
# The hooks use borgmatic's `commands` system (not deprecated before_backup/after_backup).
#
# To restore a specific PVC:
#   borgmatic extract --archive latest --restore-path exports/k3s/<namespace>/<pvc-name>/

{
  config,
  pkgs,
  lib,
  ...
}:

let
  repoPath = "/media/USB DISK/borg-repo";
  mountPoint = "/media/USB DISK";

  ensureRepoScript = pkgs.writeShellApplication {
    name = "borgmatic-ensure-repo";
    runtimeInputs = with pkgs; [
      borgbackup
      util-linux
    ];
    text = ''
      # Soft fail if the backup drive isn't mounted (exit 75 = skip this repo gracefully)
      if ! findmnt '${mountPoint}' > /dev/null; then
        echo 'LOG:INFO Backup drive not mounted, skipping (soft failure)'
        exit 75
      fi

      # Auto-initialize the borg repository on first run
      if [ ! -f '${repoPath}/config' ]; then
        echo 'LOG:INFO Initializing borg repository at ${repoPath}'
        borg init --encryption=none '${repoPath}'
      fi
    '';
  };

  preBackupScript = pkgs.writeShellApplication {
    name = "borgmatic-pre-backup";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      jq
      coreutils
    ];
    text = builtins.readFile ./scripts/pre-backup.sh;
  };

  postBackupScript = pkgs.writeShellApplication {
    name = "borgmatic-post-backup";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      coreutils
    ];
    text = builtins.readFile ./scripts/post-backup.sh;
  };
in
{
  # Make backup scripts available system-wide
  environment.systemPackages = [
    preBackupScript
    postBackupScript
  ];

  # Borgmatic service configuration
  services.borgmatic = {
    enable = true;
    settings = {
      source_directories = [ "/exports/k3s" ];
      repositories = [
        {
          path = repoPath;
          label = "local";
        }
      ];
      compression = "zstd,3";
      keep_daily = 7;
      keep_weekly = 4;
      keep_monthly = 12;
      commands = [
        {
          before = "repository";
          run = [ "${ensureRepoScript}/bin/borgmatic-ensure-repo" ];
        }
        {
          before = "configuration";
          when = [ "create" ];
          run = [ "${preBackupScript}/bin/borgmatic-pre-backup" ];
        }
        {
          after = "configuration";
          when = [ "create" ];
          states = [
            "finish"
            "fail"
          ];
          run = [ "${postBackupScript}/bin/borgmatic-post-backup" ];
        }
      ];
    };
  };

  # Override timer schedule (default from upstream package is hourly)
  systemd.timers.borgmatic.timerConfig = {
    OnCalendar = "*-*-* 03:15:00";
    Persistent = true;
  };

  # Ensure borgmatic runs after k3s is ready
  systemd.services.borgmatic = {
    wants = [
      "k3s.service"
      "network-online.target"
    ];
    after = [
      "k3s.service"
      "network-online.target"
    ];
  };
}
