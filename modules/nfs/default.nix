{ lib, pkgs, ... }:

{
  # fsType is an explicit "auto" on purpose — two constraints, one value:
  #  1) os-repo eval: nixos-26.05 declares fsType with NO default, so this
  #     entry must set it (absent breaks `nix flake check`'s mk-device).
  #  2) deployed fleet: every live fstab already reads
  #     "/mnt/k3s /exports/k3s auto bind 0 0". Kubelet pods mount this export
  #     back over loopback NFS, so the bind is busy at runtime — any fstab
  #     change (e.g. "auto"→"none") forces a mount-unit restart that cannot
  #     succeed without a reboot. Match the fleet byte-for-byte.
  # Frozen unless rebooting every device is fine.
  fileSystems."/exports/k3s" = {
    device = "/mnt/k3s";
    fsType = "auto";
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
