# Lenovo ThinkCentre M90q Gen 1 (Comet Lake, i5-10500T). Facts probed on the
# first unit, 2026-11-10: I219-LM at 00:1f.6 named eno1 (systemd onboard
# naming, not the PCI-path name the M710Q uses), Samsung PM981a NVMe.
# Identity-free by contract: no hostname, no users, no secrets.
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  # No disk layout here: the installer writes it into the device flake
  # (disk.nix), so an OS update never re-decides how this disk is laid out.
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
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

  # Onboard NIC (I219-LM, e1000e) — eno1 by onboard naming, unlike the M710Q's
  # enp0s31f6 for the same controller slot.
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;
}
