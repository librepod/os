# modules/image — the appliance as an A/B disk image: repart layout, sysupdate
# transfers, boot counting, health gate, panic/watchdog reboots.
# Design: docs/superpowers/specs/2026-11-11-ab-image-updates-design.md
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.librepod.image;
  inherit (config.system.image) id version;
  inherit (pkgs.stdenv.hostPlatform) efiArch;
  slot = {
    Type = "linux-generic";
    Minimize = "off";
    SizeMinBytes = cfg.slotSize;
    SizeMaxBytes = cfg.slotSize;
  };
in
{
  imports = [
    (modulesPath + "/image/repart.nix")
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];

  options.librepod.image = {
    updateUrl = lib.mkOption {
      type = lib.types.str;
      description = "Folder holding SHA256SUMS, SHA256SUMS.gpg and the release files.";
    };
    pubring = lib.mkOption {
      type = lib.types.path;
      description = "The only keys a release may be signed with.";
    };
    slotSize = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Size of each store slot; fixed once a device is installed.";
    };
    tries = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Boots a new version gets before the previous one comes back.";
    };
    healthCheck = lib.mkOption {
      type = lib.types.str;
      description = "ExecStart of the health gate: a counted boot is marked good only after it passes.";
    };
  };

  config = {
    system.image.id = "librepod";
    boot.loader.grub.enable = false;

    # Prefixed labels: a generic "root" or "esp" collides with any plugged-in disk.
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-partlabel/librepod-root";
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/disk/by-partlabel/librepod-esp";
        fsType = "vfat";
      };
      # The version is baked into this UKI's initrd: each UKI mounts its own slot.
      "/nix/store" = {
        device = "/dev/disk/by-partlabel/store_${version}";
        fsType = "squashfs";
      };
    };

    image.repart = {
      name = id;
      # Also writes the store partition alone: the release's slot image.
      split = true;
      partitions = {
        esp = {
          contents = {
            "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          };
          repartConfig = {
            Type = "esp";
            Label = "librepod-esp";
            Format = "vfat";
            SizeMinBytes = "256M";
            SplitName = "-";
          };
        };
        store-a = {
          storePaths = [ config.system.build.toplevel ];
          nixStorePrefix = "/";
          repartConfig = slot // {
            Label = "store_${version}";
            Format = "squashfs";
            ReadOnly = "yes";
            SplitName = "store";
          };
        };
        store-b.repartConfig = slot // {
          Label = "_empty";
          SplitName = "-";
        };
        # shortcut: fixed 512M root, grown on first boot by systemd-repart in the product
        root.repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "librepod-root";
          Minimize = "off";
          SizeMinBytes = "512M";
          SizeMaxBytes = "512M";
          SplitName = "-";
        };
      };
    };

    systemd.sysupdate = {
      enable = true;
      transfers =
        let
          from = suffix: {
            # Never reuse the running version's slot or UKI.
            Transfer.ProtectVersion = "%A";
            Source = {
              Type = "url-file";
              Path = cfg.updateUrl;
              MatchPattern = "${id}_@v.${suffix}";
            };
          };
        in
        {
          "10-store" = from "store.raw.zst" // {
            Target = {
              Type = "partition";
              Path = "auto";
              MatchPattern = "store_@v";
              MatchPartitionType = "linux-generic";
              ReadOnly = "yes";
              InstancesMax = 2;
            };
          };
          "20-uki" = from "efi" // {
            Target = {
              Type = "regular-file";
              Path = "/EFI/Linux";
              PathRelativeTo = "boot";
              # Boot counting: installed as +tries-0, renamed by systemd-boot on
              # every boot and by systemd-bless-boot once the health gate passes.
              MatchPattern = [
                "${id}_@v+@l-@d.efi"
                "${id}_@v+@l.efi"
                "${id}_@v.efi"
              ];
              Mode = "0644";
              TriesLeft = cfg.tries;
              TriesDone = 0;
              InstancesMax = 2;
            };
          };
        };
    };
    # Only the consent updater starts an update, never a timer.
    systemd.timers.systemd-sysupdate.wantedBy = lib.mkForce [ ];
    # When this exists, systemd-pull ignores the vendor keyring.
    environment.etc."systemd/import-pubring.pgp".source = cfg.pubring;
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "systemd-sysupdate";
        # systemd-pull looks gpg up in PATH; without it every release is
        # refused, so a unit's bare PATH would block all updates.
        runtimeInputs = [ pkgs.gnupg ];
        text = ''exec ${config.systemd.package}/lib/systemd/systemd-sysupdate "$@"'';
      })
    ];

    # Pulled in only on counted boots: systemd-bless-boot requires
    # boot-complete.target, and that requires this.
    systemd.services.librepod-health = {
      description = "LibrePod health gate for a new version";
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      unitConfig.FailureAction = "reboot";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = cfg.healthCheck;
        TimeoutStartSec = "15min";
      };
    };

    # A panic or a hang reboots by itself; boot counting does the rest.
    boot.kernelParams = [ "panic=10" ];
    systemd.settings.Manager.RuntimeWatchdogSec = lib.mkDefault "30s";
  };
}
