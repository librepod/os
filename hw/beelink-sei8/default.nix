# Beelink SEi8: LUKS root (unlocked by USB keyFile at boot, falling back to
# password), SD-card reader, dedicated /mnt/k3s data mount, swap.
# Identity-free by contract: no hostname, no users, no secrets.
# Merged from the private fleet's boot.nix + disko-luks.nix: disko owns what
# it generates (/, /boot, the LUKS device); this module adds the boot-time
# keyFile policy, /mnt/k3s, swap, and model-specific kernel bits.
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.initrd.kernelModules = [ "dm-snapshot" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Merged with the luks device disko generates ("crypted"): disko provides
  # the device path and keyFile; this adds boot-time policy.
  boot.initrd.luks.devices.crypted = {
    # USB key inserted in the device; falls back to password prompt without it.
    keyFileSize = 4096;
    fallbackToPassword = true;
  };

  fileSystems."/mnt/k3s" = {
    device = "/dev/disk/by-label/data";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];

  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "500M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" ];
              };
            };
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted";
                extraOpenArgs = [ ];
                settings = {
                  allowDiscards = true;
                  keyFile = "/dev/sdb1";
                };
                additionalKeyFiles = [ ];
                content = {
                  type = "lvm_pv";
                  vg = "pool";
                };
              };
            };
          };
        };
      };
      # ponytail: USB key disk (keyFile source) is fleet-specific, not
      # model-generic; installer/provisioner adds it per device if used.
    };
    lvm_vg = {
      pool = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "defaults" ];
            };
          };
        };
      };
    };
  };
}
