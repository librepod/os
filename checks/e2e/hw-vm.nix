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

  # The E2E release repo's flake.lock uses path nodes (no git rev), while the
  # host prebuild evaluates against github-locked inputs; the default
  # system.nixos.version embeds that rev, so the two evals would produce
  # differently-named (unsubstitutable) toplevels. Pin it rev-free.
  system.nixos.version = "25.11";

  # The appliance disables global DHCP — hardware profiles declare their NIC.
  # net.ifnames=0 (test instrumentation) names the virtio NIC eth0.
  networking.interfaces.eth0.useDHCP = true;
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
