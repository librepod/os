# modules/data-disk — an image device's PVs live on its data disk, found by the
# partition UUID on root; the disk's format is listed in modules/identity.
{ pkgs, ... }:
{
  # Another LibrePod's data disk carries the same label: match the recorded UUID.
  services.udev.extraRules = ''
    SUBSYSTEM=="block", ENV{ID_PART_ENTRY_NAME}=="librepod-data", PROGRAM="${pkgs.gnugrep}/bin/grep -qxF $env{ID_PART_ENTRY_UUID} /etc/librepod/data-partuuid", SYMLINK+="disk/librepod-data"
  '';
  # Without the data disk the device still boots, but the bind and NFS stay
  # down, so PVs never land on root.
  fileSystems."/mnt/k3s" = {
    device = "/dev/disk/librepod-data";
    fsType = "ext4";
    options = [ "nofail" ];
  };
  fileSystems."/exports/k3s".options = [ "nofail" ];
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = "/exports/k3s";
}
