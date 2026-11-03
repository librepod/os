# An install.nix as librepod-install writes it (see pkgs/librepod-install),
# with the layout it copied in on install day (disk.nix, frozen here).
{
  imports = [ ./disk.nix ];
  disko.devices.disk.main.device = "/dev/nvme0n1";
  system.stateVersion = "21.11";
}
