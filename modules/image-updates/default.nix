# modules/image-updates — what updates an image device: the owner's CLI and the
# timer's tick (librepod-update) and the health gate of a new version. The OS
# agent (modules/os-agent) is what calls the CLI for the Marketplace.
# The sysupdate definitions per channel come from modules/image.
# Design: docs/superpowers/specs/2026-11-11-ab-image-updates-design.md
{
  config,
  lib,
  pkgs,
  ...
}:
let
  scripts = import ./scripts.nix {
    inherit (pkgs) writeShellApplication;
    runtimeInputs = with pkgs; [
      jq
      coreutils
      gnugrep
      gnused
      util-linux # flock
      config.system.build.sysupdate
      config.systemd.package
    ];
    healthInputs = with pkgs; [
      curl
      gnupg
      k3s
    ];
  };
  inherit (scripts) updater health;
  # Where the scripts' `date` reads time zones from.
  TZDIR = "${pkgs.tzdata}/share/zoneinfo";
  blessBoot = "${config.systemd.package}/lib/systemd/systemd-bless-boot";
in
{
  options.librepod.updates.cli = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "The updater's CLI (librepod-update), for the OS agent.";
  };

  config = {
    librepod.updates.cli = updater;
    librepod.image.healthCheck = "${health}/bin/librepod-update-health";

    environment.systemPackages = [ updater ];
    systemd.tmpfiles.rules = [ "d /var/lib/librepod/updates 0700 root root -" ];

    systemd.services = {
      # What the timer, and the CLI's check and install, run: check, download,
      # install when due.
      librepod-update = {
        description = "LibrePod update: check, download, install";
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "librepod-update-fallback.service"
        ];
        environment = {
          inherit TZDIR;
          LIBREPOD_BLESS_BOOT = blessBoot; # tick settles a finished install too
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updater}/bin/librepod-update tick";
          # A 2 GB download on a slow link. systemd-pull aborts a stalled transfer
          # itself, so this cap is only for hangs.
          TimeoutStartSec = "12h";
        };
      };

      # Before k3s on every boot: after a failed update, k3s must not start on
      # the new version's data. wantedBy, not requiredBy: a failure here must
      # never keep k3s down. Once per boot, so the install's own k3s restart
      # can't run it again.
      librepod-update-fallback = {
        description = "LibrePod update: fall back after a failed new version";
        wantedBy = [ "k3s.service" ];
        before = [ "k3s.service" ];
        unitConfig.ConditionPathExists = "/var/lib/librepod/updates/record.json";
        environment = { inherit TZDIR; };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${updater}/bin/librepod-update fallback";
        };
      };

      # Counted boots only: that is when systemd-bless-boot runs.
      librepod-update-finish = {
        description = "LibrePod update: settle an install once its version is blessed";
        wantedBy = [ "systemd-bless-boot.service" ];
        after = [ "systemd-bless-boot.service" ];
        environment = {
          inherit TZDIR;
          LIBREPOD_BLESS_BOOT = blessBoot;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updater}/bin/librepod-update finish";
        };
      };

    };

    systemd.timers = {
      # Catches the night window; the 6 h rule for checking lives in the script.
      librepod-update = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "15min";
          RandomizedDelaySec = "5min";
        };
      };
    };
  };
}
