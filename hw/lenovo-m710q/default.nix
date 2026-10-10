# Lenovo ThinkCentre M710Q (also fits the generic Intel mini-PCs in the
# personal fleet: same not-detected scan, same kernel modules).
# Identity-free by contract: no hostname, no users, no secrets.
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    # Default disk layout (GPT, ESP 500M, LVM ext4 root, device mkDefault
    # /dev/nvme0n1) — imported here so the profile is self-contained.
    ../../modules/disko
  ];

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
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Onboard NIC on all M710Qs (model-generic).
  networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;
}
