{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.librepod.updates;

  inherit
    (import ./scripts.nix {
      inherit (pkgs) writeShellApplication;
      runtimeInputs = with pkgs; [
        nix
        jq
        k3s
        coreutils # timeout, stat, date
        config.systemd.package # bootctl, matching the running systemd
      ];
    })
    updater
    sentinel
    ;

  stateDir = "/var/lib/librepod";
in
{
  options.librepod.updates = {
    enable = lib.mkEnableOption "consent-driven LibrePod OS self-updates";
  };

  config = lib.mkIf cfg.enable {
    # The updater drives `nix flake update` / `nix build` on-device.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services.librepod-updater = {
      description = "LibrePod OS updater — poll consent, apply release";
      after = [
        "network-online.target"
        "k3s.service"
        # Never alongside it: both clear up update-pending.
        "librepod-update-sentinel.service"
      ];
      wants = [ "network-online.target" ];
      environment.LIBREPOD_STATE_DIR = stateDir;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updater}/bin/librepod-updater";
        # A hung command (kubectl has no request timeout) would stop the polls
        # until a reboot. Leaves room for a full system download on a slow link.
        TimeoutStartSec = "2h";
      };
    };

    systemd.timers.librepod-updater = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };

    systemd.services.librepod-update-sentinel = {
      description = "LibrePod update sentinel — commit or end the trial boot";
      wantedBy = [ "multi-user.target" ];
      # Boot counting (GitHub #17) will mark a boot good only after this passes.
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      after = [
        "network-online.target"
        "k3s.service"
      ];
      wants = [ "network-online.target" ];
      environment.LIBREPOD_STATE_DIR = stateDir;
      unitConfig.ConditionPathExists = "${stateDir}/update-pending";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${sentinel}/bin/librepod-update-sentinel";
        # 15 min health budget + slack; the script also self-limits.
        TimeoutStartSec = "25min";
      };
    };
  };
}
