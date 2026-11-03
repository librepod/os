{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.librepod.updates;

  # Shared env/status scaffolding, prepended to both scripts so they can't
  # drift (env defaults, kctl, current_version, report, update-pending).
  common = builtins.readFile ./common.sh;

  mkScript =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        nix
        jq
        k3s
        config.systemd.package # bootctl, matching the running systemd
      ];
      text = common + text;
    };

  updater = mkScript "librepod-updater" (builtins.readFile ./updater.sh);
  sentinel = mkScript "librepod-update-sentinel" (builtins.readFile ./sentinel.sh);

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
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updater}/bin/librepod-updater";
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
      unitConfig.ConditionPathExists = "${stateDir}/update-pending";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${sentinel}/bin/librepod-update-sentinel";
        # 15 min health budget + slack; the script also self-limits.
        TimeoutStartSec = "25min";
      };
    };

    # Appliance GC: keep ~a month of generations for rollback; identity may override.
    nix.gc = lib.mkDefault {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };
}
