{ pkgs, lib, machineConfig, ... }:
let
  librepodRule = import ./librepod { inherit pkgs machineConfig; };
  traefikRule = import ./traefik { inherit pkgs machineConfig; };
  nfsProvisionerRule = import ./nfs-provisioner { inherit pkgs machineConfig; };
  piholeRule = import ./pihole { inherit pkgs machineConfig; };
  wgEasyRule = import ./wg-easy { inherit pkgs machineConfig; };
  kubernetesDashboardRule = import ./kubernetes-dashboard { inherit pkgs machineConfig; };
  kubeappsRule = import ./kubeapps { inherit pkgs machineConfig; };
  hajimariRule = import ./hajimari { inherit pkgs machineConfig; };
  forecastleRule = import ./forecastle { inherit pkgs machineConfig; };
  filebrowserRule = import ./filebrowser { inherit pkgs machineConfig; };
in
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString ([
      (if machineConfig.nfsProvisioner.enable then "--disable local-storage" else "")
    ] ++ machineConfig.k3sExtraFlags);
  };

  # Allow some ports
  # 53 - DNS
  # 80,443 - http, https
  # 1080 - xray/v2ray proxy port
  # 6443 - Kubernetes API Server
  # 10250	- Kubelet metrics
  # 22000 - Syncthing ports (both TCP and UDP)
  # 7400 - frpc admin port
  networking.firewall.allowedTCPPorts = [ 53 80 443 1080 6443 10250 22000 7400 ];
  networking.firewall.allowedUDPPorts = [ 53 51820 22000 ];

  environment.systemPackages = [ pkgs.k3s ];

  # Read here for rules description:
  # https://www.man7.org/linux/man-pages/man5/tmpfiles.d.5.html
  systemd.tmpfiles.rules = [
    librepodRule
    traefikRule
    (lib.mkIf machineConfig.nfsProvisioner.enable nfsProvisionerRule)
    (lib.mkIf machineConfig.pihole.enable piholeRule)
    (lib.mkIf machineConfig.wgEasy.enable wgEasyRule)
    (lib.mkIf machineConfig.kubernetesDashboard.enable kubernetesDashboardRule)
    (lib.mkIf machineConfig.kubeapps.enable kubeappsRule)
    (lib.mkIf machineConfig.hajimari.enable hajimariRule)
    (lib.mkIf machineConfig.forecastle.enable forecastleRule)
    (lib.mkIf machineConfig.filebrowser.enable filebrowserRule)
  ];
}
