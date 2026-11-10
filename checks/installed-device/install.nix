# An install.nix as librepod-install writes it (see pkgs/librepod-install),
# with the layout it copied in on install day (disk.nix, frozen here).
{
  imports = [ ./disk.nix ];
  disko.devices.disk.main.device = "/dev/nvme0n1";
  disko.devices.disk.data.device = "/dev/sda";
  system.stateVersion = "26.05";
}
