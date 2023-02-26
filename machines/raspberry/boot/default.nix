{ lib, pkgs, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_rpi4;
    tmpOnTmpfs = true;
    initrd.availableKernelModules = [ "usbhid" "usb_storage" ];
    # ttyAMA0 is the serial console broken out to the GPIO
    kernelParams = [
        "8250.nr_uarts=1"
        "console=ttyAMA0,115200"
        "console=tty1"

        # Some gui programs need this
        "cma=128M"

        # These two are for Raspberry Pi 4 only
        "cgroup_memory=1"
        "cgroup_enable=memory"
    ];
    loader = {
      raspberryPi = {
        enable = true;
        version = 4;
      };
      # Use the extlinux boot loader. (NixOS wants to enable GRUB by default)
      grub.enable = false;
      # Enables the generation of /boot/extlinux/extlinux.conf
      generic-extlinux-compatible.enable = true;
    };
  };
}
