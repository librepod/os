{ lib, pkgs, ... }:

{
  fileSystems."/exports/k3s" = {
    device = "/mnt/k3s";
    options = [ "bind" ];
  };

  services.nfs = {
    server.enable = true;
    server.exports = ''
      /exports/k3s     *(rw,sync,no_root_squash,crossmnt,subtree_check)
    '';
  };

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
