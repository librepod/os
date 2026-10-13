# checks/e2e/hw-vm.nix — QEMU hardware module for the E2E appliance.
# Mirrors hw/lenovo-m710q minus the physical disk layout: the test framework
# builds the disk image (root label "nixos", ESP label "ESP" — both hard-coded
# by qemu-vm.nix), so no disko layout here. Self-contained on purpose: the
# device flake evaluates this WITHOUT qemu-vm.nix, so file systems and the
# bootloader are stated, not inherited from the VM module.
{
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [
    "virtio_net"
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # qemu-vm.nix disk image labels; superseded by mkVMOverride inside the
  # test node, authoritative in the standalone device-flake eval.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
}
