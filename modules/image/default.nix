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
  # usr and usr-verity, the types the verity phase needs: an installed
  # partition keeps its type, and sysupdate tells a slot from its hashes by it.
  slot = {
    Type = "usr";
    Minimize = "off";
    SizeMinBytes = cfg.slotSize;
    SizeMaxBytes = cfg.slotSize;
  };
  # Reserved for the verity phase: 8 GiB of 4 KiB blocks hash to ~65 MiB.
  veritySlot = {
    Type = "usr-verity";
    Label = "_empty";
    Minimize = "off";
    SizeMinBytes = "128M";
    SizeMaxBytes = "128M";
    SplitName = "-";
  };
  # This profile's files in a release: <releaseId>_<version>.<suffix>.
  releaseId = id + lib.optionalString (cfg.profile != null) "-${cfg.profile}";
  releaseName = "${releaseId}_${version}";
  # systemd-pull looks gpg up in PATH; without it every release is refused, so
  # a unit's bare PATH would block all updates.
  sysupdate = pkgs.writeShellApplication {
    name = "systemd-sysupdate";
    runtimeInputs = [ pkgs.gnupg ];
    text = ''exec ${config.systemd.package}/lib/systemd/systemd-sysupdate "$@"'';
  };
  ini = pkgs.formats.ini { listToValue = toString; };
  channels = {
    stable = cfg.updateUrl;
    beta = cfg.betaUrl;
  };
  # The transfers of the channel whose release files are at url.
  transfers =
    url:
    let
      from = suffix: {
        # Never reuse the running version's slot or UKI.
        Transfer.ProtectVersion = "%A";
        Source = {
          Type = "url-file";
          Path = url;
          MatchPattern = "${releaseId}_@v.${suffix}";
        };
      };
    in
    {
      "10-store" = from "store.raw.zst" // {
        Target = {
          Type = "partition";
          Path = "auto";
          MatchPattern = "store_@v";
          MatchPartitionType = "usr";
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
  # udev marks the disk systemd-boot started from (initrd) and the disk holding
  # / (after the switch): a copy of this image on another drive is never mounted.
  bootDiskRules = ''
    SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", IMPORT{parent}="ID_PART_GPT_AUTO_ROOT_DISK"
    SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{ID_PART_ENTRY_NAME}=="?*", SYMLINK+="disk/librepod-os/$env{ID_PART_ENTRY_NAME}"
  '';
in
{
  imports = [
    (modulesPath + "/image/repart.nix")
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];

  options.librepod.image = {
    updateUrl = lib.mkOption {
      type = lib.types.str;
      # Only the newest stable release is offered; older ones stay under their tags.
      default = "https://github.com/librepod/os/releases/latest/download/";
      description = "Folder holding SHA256SUMS, SHA256SUMS.gpg and the release files.";
    };
    betaUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/librepod/os/releases/download/beta/";
      description = "The beta channel's folder: the same files as updateUrl, for devices that chose beta.";
    };
    pubring = lib.mkOption {
      type = lib.types.path;
      default = ../../keys/release.pgp;
      description = "The only keys a release may be signed with.";
    };
    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hardware profile: a release holds every profile's files, named librepod-<profile>_<version>.";
    };
    slotSize = lib.mkOption {
      type = lib.types.str;
      default = "8G";
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

    # Prefixed labels: a generic "root" or "esp" collides with any plugged-in
    # disk. The librepod-os links make them unique per disk: only the boot disk's.
    boot.initrd.services.udev.rules = bootDiskRules;
    services.udev.extraRules = bootDiskRules;
    fileSystems = {
      "/" = {
        device = "/dev/disk/librepod-os/librepod-root";
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/disk/librepod-os/librepod-esp";
        fsType = "vfat";
      };
      # The version is baked into this UKI's initrd: each UKI mounts its own slot.
      "/nix/store" = {
        device = "/dev/disk/librepod-os/store_${version}";
        fsType = "squashfs";
      };
    };

    image.repart = {
      name = id;
      # Also writes the store partition alone: the release's slot image.
      split = true;
      # Written in name order: root last, so the installer can grow it.
      partitions = {
        "10-esp" = {
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
            SizeMinBytes = "1G";
            SplitName = "-";
          };
        };
        "20-store-a" = {
          storePaths = [ config.system.build.toplevel ];
          nixStorePrefix = "/";
          repartConfig = slot // {
            Label = "store_${version}";
            Format = "squashfs";
            ReadOnly = "yes";
            SplitName = "store";
          };
        };
        "25-store-a-verity".repartConfig = veritySlot;
        "30-store-b".repartConfig = slot // {
          Label = "_empty";
          SplitName = "-";
        };
        "35-store-b-verity".repartConfig = veritySlot;
        # The installer grows it to fill the disk.
        "40-root".repartConfig = {
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

    # The stable channel's transfers: what systemd-sysupdate reads on its own.
    systemd.sysupdate = {
      enable = true;
      transfers = transfers cfg.updateUrl;
    };
    # What a release publishes for this profile: the UKI and store slot devices
    # update from, and the whole disk librepod-install writes.
    system.build.releaseFiles =
      pkgs.runCommand "${releaseName}-release" { nativeBuildInputs = [ pkgs.zstd ]; }
        ''
          mkdir $out
          cp ${config.system.build.uki}/${config.system.boot.loader.ukiFile} $out/${releaseName}.efi
          zstd -q -T0 ${config.system.build.image}/${config.image.baseName}.store.raw -o $out/${releaseName}.store.raw.zst
          zstd -q -T0 ${config.system.build.image}/${config.image.filePath} -o $out/${releaseName}.raw.zst
        '';

    # Only librepod-update starts an update, never a timer.
    systemd.timers.systemd-sysupdate.wantedBy = lib.mkForce [ ];
    environment.etc = {
      # When this exists, systemd-pull ignores the vendor keyring.
      "systemd/import-pubring.pgp".source = cfg.pubring;
      # One definition set per channel, for librepod-update to pass to
      # systemd-sysupdate: the channel is the owner's choice, made at run time.
      "librepod/channels.json".text = builtins.toJSON channels;
    }
    // lib.concatMapAttrs (
      channel: url:
      lib.mapAttrs' (name: value: {
        name = "librepod/sysupdate/${channel}/${name}.transfer";
        value.source = ini.generate "${name}.transfer" value;
      }) (transfers url)
    ) channels;
    environment.systemPackages = [ sysupdate ];
    system.build.sysupdate = sysupdate;

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

    # A panic, a failed initrd or a hang reboots by itself; boot counting does the rest.
    boot.kernelParams = [
      "panic=10"
      "boot.panic_on_fail"
    ];
    systemd.settings.Manager.RuntimeWatchdogSec = lib.mkDefault "30s";
    # A failed mount stops the boot in emergency mode, before the health gate,
    # and root is locked so there is no shell either: reboot instead.
    systemd.services.librepod-emergency-reboot = {
      wantedBy = [ "emergency.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.ExecStart = "${config.systemd.package}/bin/systemctl --no-block reboot";
    };
  };
}
