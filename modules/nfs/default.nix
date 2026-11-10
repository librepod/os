{ lib, pkgs, ... }:

{
  # fsType must stay at its default ("auto"): kubelet pods mount this export
  # back over loopback NFS, so the mount is busy at runtime — any fstab change
  # (even cosmetic, like fsType "auto"→"none") forces a restart that cannot
  # succeed without a reboot. Frozen unless rebooting every device is fine.
  fileSystems."/exports/k3s" = {
    device = "/mnt/k3s";
    options = [ "bind" ];
  };
  # A fresh disk has no /mnt/k3s, and a bind mount from a missing source fails
  # local-fs.target (emergency mode). Activation runs before systemd mounts it.
  system.activationScripts.k3s-export-source = "mkdir -p /mnt/k3s";

  services.nfs = {
    server.enable = true;
    server.exports = ''
      /exports/k3s      *(rw,sync,no_root_squash,crossmnt,subtree_check)
    '';
  };

  networking.firewall.allowedTCPPorts = [ 2049 ];

  # PVs live on this export (the marketplace's nfs-provisioner mounts
  # 127.0.0.1:/exports/k3s), so k3s's own local-path provisioner goes.
  services.k3s.disable = [ "local-storage" ];
}
