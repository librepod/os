# Shared backup hook scripts for consistent k8s PVC backups (issue #12).
#
# Both the borgmatic and duplicati modules need the same dance around their
# backup run: suspend Flux, scale PVC-backed deployments to 0 (recording
# replica counts in a persistent state file), back up, then restore. If a
# reboot interrupts the window, a boot-time recovery unit reruns the restore
# while the state file survives.
#
# State-file WAL rule: written before scale-down, never truncated, consumed
# only after a fully successful restore (it is both the recovery trigger and
# the only record of desired replica counts).
#
# Args:
#   toolName       — script/unit name prefix ("borgmatic", "duplicati");
#                    binary names stay <toolName>-{pre,post}-backup
#   stateFilePath  — persistent state file; its parent directory must be the
#                    tool's StateDirectory (e.g. /var/lib/<toolName>/…)
#   backupUnitName — unit that runs the backup. Recovery skips while it is
#                    active/activating: `nixos-rebuild switch` starts newly-
#                    wanted units too, and firing a restore under a running
#                    backup would race it and delete the state file.
{
  toolName,
  stateFilePath,
  backupUnitName,
  pkgs,
}:
let
  stateDirName = builtins.baseNameOf (builtins.dirOf stateFilePath);

  preBackupScript = pkgs.writeShellApplication {
    name = "${toolName}-pre-backup";
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
          "${postBackupScript}/bin/${toolName}-post-backup"
        ]
        (builtins.readFile ./scripts/pre-backup.sh);
  };

  postBackupScript = pkgs.writeShellApplication {
    name = "${toolName}-post-backup";
    runtimeInputs = with pkgs; [
      k3s
      fluxcd
      coreutils
    ];
    text = builtins.replaceStrings [ "@STATE_FILE@" ] [ stateFilePath ] (
      builtins.readFile ./scripts/post-backup.sh
    );
  };
in
{
  inherit preBackupScript postBackupScript stateFilePath;

  # Assign to systemd.services."<toolName>-recovery" from the consuming
  # module. Steps are idempotent, so reruns on a stale file are harmless;
  # ConditionPathExists skips it entirely when no state file exists.
  recoveryService = {
    description = "Restore workloads after interrupted ${toolName} backup";
    wantedBy = [ "multi-user.target" ];
    wants = [ "k3s.service" ];
    after = [ "k3s.service" ];
    unitConfig.ConditionPathExists = stateFilePath;
    path = [ pkgs.systemd ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = stateDirName;
      # A failed boot-time attempt (e.g. Flux controllers not Ready yet at
      # cold boot) must not strand the fleet at 0 replicas: the state file
      # is only consumed on full success, so retry until it is.
      Restart = "on-failure";
      RestartSec = 60;
    };
    # Guard: skip while the backup unit runs — its own post-backup step will
    # restore. Type=oneshot reports ActiveState=activating while running.
    script = ''
      state=$(systemctl show -p ActiveState --value ${backupUnitName} 2>/dev/null || echo inactive)
      if [ "$state" != inactive ] && [ "$state" != failed ]; then
        echo "LOG:INFO ${backupUnitName} is '$state' — backup in flight, its post-backup step will restore the fleet"
        exit 0
      fi
      exec ${postBackupScript}/bin/${toolName}-post-backup
    '';
  };
}
