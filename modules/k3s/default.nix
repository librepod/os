{ pkgs, lib, machineConfig, ... }:
let
  librepodRule = import ./librepod { inherit pkgs machineConfig; };
  argocdRule = import ./argocd { inherit pkgs machineConfig; };
in
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = machineConfig.k3sExtraFlags;
  };

  # Allow some ports
  # 53 - DNS
  # 80,443 - http, https
  # 1080 - xray/v2ray proxy port
  # 6443 - Kubernetes API Server
  # 10250 - Kubelet metrics
  # 22000 - Syncthing ports (both TCP and UDP)
  # 7400 - frpc admin port
  networking.firewall.allowedTCPPorts = [ 53 80 443 1080 6443 10250 22000 7400 ];
  networking.firewall.allowedUDPPorts = [ 53 51820 22000 ];

  environment.systemPackages = [ pkgs.k3s ];

  # Read here for rules description:
  # https://www.man7.org/linux/man-pages/man5/tmpfiles.d.5.html
  systemd.tmpfiles.rules = [
    librepodRule
    argocdRule
  ];
}
