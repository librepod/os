# Borgmatic backup module with FluxCD integration
#
# This module configures borgmatic for automated nightly backups of k3s PVC data.
# All PVCs are backed up by default; label `backup.libre.pod/disabled=true` to skip.
# Borg's content-addressed storage enables per-PVC restore via path-based extraction
# without requiring separate backup jobs per PVC.
#
# Pre/post backup hooks suspend/resume HelmReleases and FluxCD Kustomizations,
# then scale K8s deployments for consistent snapshots.
# The hooks use borgmatic's `commands` system (not deprecated before_backup/after_backup).
#
# Post-backup order (all three are required):
#   1. Resume HelmReleases (remove suspend flag set by pre-backup)
#   2. Restore scaled-down deployments (Helm's three-way merge won't do it)
#   3. Resume Kustomizations (Jobs find healthy services)
#
# Helm's three-way strategic merge preserves externally-scaled replicas on
# upgrade, so the pre-backup script saves replica counts to a state file and
# the post-backup script restores them explicitly. See post-backup.sh for the
# full SSA field-ownership explanation. The state file lives under /var/lib
# (persistent): if a reboot interrupts the backup window, suspend flags in
# etcd and replicas=0 survive while /run does not — borgmatic-recovery.service
# reruns post-backup at boot while the state file exists (issue #12).
#
# Dynamic source directories:
#   A generate-sources script queries k8s for labeled PVCs, resolves their NFS paths
#   via the bound PV's spec.nfs.path, and writes them to /run/borgmatic/sources.yaml.
#   The base borgmatic config includes this file via <<: !include (deep merge).
#   Because pkgs.formats.yaml cannot produce the custom <<: !include YAML tag,
#   we use runCommand to prepend it to the generated config.
#
# To skip a PVC from backup:
#   kubectl label pvc <pvc-name> -n <namespace> backup.libre.pod/disabled=true
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

  # Single source of truth for the replica-state file path (issue #12):
  # substituted into both hook scripts (@STATE_FILE@) and used by
  # borgmatic-recovery.service's ConditionPathExists.
  stateFilePath = "/var/lib/borgmatic/scaled-deployments.txt";

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

  generateSourcesScript = pkgs.writeShellApplication {
    name = "borgmatic-generate-sources";
    runtimeInputs = with pkgs; [
      k3s
      jq
      coreutils
    ];
    text = builtins.readFile ./scripts/generate-sources.sh;
  };

  preBackupScript = pkgs.writeShellApplication {
    name = "borgmatic-pre-backup";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      jq
      coreutils
    ];
    text =
      builtins.replaceStrings
        [ "@STATE_FILE@" "@POST_BACKUP@" ]
        [
          stateFilePath
          "${postBackupScript}/bin/borgmatic-post-backup"
        ]
        (builtins.readFile ./scripts/pre-backup.sh);
  };

  postBackupScript = pkgs.writeShellApplication {
    name = "borgmatic-post-backup";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      coreutils
    ];
    text = builtins.replaceStrings [ "@STATE_FILE@" ] [ stateFilePath ] (
      builtins.readFile ./scripts/post-backup.sh
    );
  };

  # Recovery entry point. Newly-wanted units are started by `nixos-rebuild
  # switch` too, not just at boot — so deploying this module during the backup
  # window would otherwise run post-backup mid-borg-create and delete the state
  # file under the running backup. borgmatic.service is Type=oneshot, so it
  # reports ActiveState=activating while its hooks run: anything but
  # inactive/failed means a backup is in flight and its own post-backup hook
  # will do the restore.
  recoveryScript = pkgs.writeShellApplication {
    name = "borgmatic-recovery";
    runtimeInputs = with pkgs; [ systemd ];
    text = ''
      state=$(systemctl show -p ActiveState --value borgmatic.service 2>/dev/null || echo inactive)
      if [ "$state" != inactive ] && [ "$state" != failed ]; then
        echo "LOG:INFO borgmatic.service is '$state' — backup in flight, its post-backup hook will restore the fleet"
        exit 0
      fi
      exec ${postBackupScript}/bin/borgmatic-post-backup
    '';
  };

  # Generate structured borgmatic config, then prepend the <<: !include directive.
  # pkgs.formats.yaml cannot produce custom YAML tags (like !include) or unquoted
  # merge keys (<<), so we concatenate: raw include line + generated YAML body.
  borgmaticConfig =
    let
      rawConfig = (pkgs.formats.yaml { }).generate "borgmatic-raw.yaml" {
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
    in
    pkgs.runCommand "borgmatic-config.yaml" { } ''
      echo '<<: !include /run/borgmatic/sources.yaml' > $out
      cat ${rawConfig} >> $out
    '';
in
{
  # Make backup scripts available system-wide
  environment.systemPackages = [
    generateSourcesScript
    preBackupScript
    postBackupScript
  ];

  # Borgmatic service configuration
  services.borgmatic = {
    enable = true;
    settings = { };
  };

  # Custom borgmatic config with <<: !include for dynamic source directories.
  # Overrides the empty config generated by services.borgmatic.settings.
  environment.etc."borgmatic/config.yaml".source = lib.mkForce borgmaticConfig;

  # Override timer schedule (default from upstream package is hourly).
  # Explicit UTC suffix: pins the schedule regardless of time.timeZone.
  systemd.timers.borgmatic.timerConfig = {
    OnCalendar = "*-*-* 01:15:00 UTC";
    Persistent = true;
  };

  # Ensure borgmatic runs after k3s is ready, and generate dynamic sources before backup
  systemd.services.borgmatic = {
    wants = [
      "k3s.service"
      "network-online.target"
    ];
    after = [
      "k3s.service"
      "network-online.target"
      # Pure ordering (no wants): serialize with boot recovery in case the
      # Persistent timer fires a catch-up backup while recovery is restoring.
      "borgmatic-recovery.service"
    ];
    serviceConfig.ExecStartPre = [
      "${pkgs.coreutils}/bin/mkdir -p /run/borgmatic"
      "${generateSourcesScript}/bin/borgmatic-generate-sources"
    ];
  };

  # Boot-time recovery from a reboot during the backup window (issue #12):
  # a surviving state file means a backup was interrupted mid-run — the fleet
  # is at 0 replicas with Flux suspended. Rerun the post-backup script
  # (resume HelmReleases, scale up from the state file, resume Kustomizations)
  # before the cluster serves traffic. Every step is idempotent, so reruns on
  # a stale file are harmless. Skipped entirely when no state file exists.
  systemd.services.borgmatic-recovery = {
    description = "Restore workloads after interrupted borgmatic backup";
    wantedBy = [ "multi-user.target" ];
    wants = [ "k3s.service" ];
    after = [ "k3s.service" ];
    unitConfig.ConditionPathExists = stateFilePath;
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "borgmatic";
      ExecStart = "${recoveryScript}/bin/borgmatic-recovery";
      # A failed boot-time attempt (e.g. Flux controllers not Ready yet at
      # cold boot) must not strand the fleet at 0 replicas: the state file is
      # only consumed on full success, so retry until it is.
      Restart = "on-failure";
      RestartSec = 60;
    };
  };
}
