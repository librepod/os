{
  config,
  pkgs,
  lib,
  ...
}:
{

  # INFO: See this on how to reset cluster and start fresh:
  # https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/networking/cluster/k3s/docs/CLUSTER_UPKEEP.md
  # Also see the reset-k3s target in Justfile
  #
  # Dismount kubelet:
  # KUBELET_PATH=$(mount | grep kubelet | cut -d' ' -f3)
  # ${KUBELET_PATH:+umount $KUBELET_PATH}
  # Delete k3s data:
  # rm -rf /etc/rancher/{k3s,node}
  # rm -rf /var/lib/{rancher/k3s,kubelet,longhorn,etcd,cni}
  services.k3s = {
    enable = true;
    role = "server";
    package = pkgs.k3s;
    # Disabling local-storage since we are going to use nfs and nfs-provisioner
    # Disabling traefik since we are going to deploy and configure it with argocd
    extraFlags = "--disable=local-storage --disable=traefik";
    # Allow unsafe sysctls needed for WireGuard and other networking workloads
    # net.ipv4.conf.all.src_valid_mark: Required for WireGuard packet marking
    # See here https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
    # NOTE: allowedUnsafeSysctls must be a list of strings, not a single string
    extraKubeletConfig = {
      allowedUnsafeSysctls = [
        "net.ipv4.conf.all.src_valid_mark" # wg-easy needs this
        "net.ipv4.ip_forward" # traefik needs this
      ];
    };
    # Auto-deploy charts for K3S
    # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/cluster/k3s/default.nix
    autoDeployCharts = {
      flux-operator = import ./charts/flux-operator.nix;
      flux-instance = import ./charts/flux-instance.nix;
    };
  };

  # Allow some ports
  # 53 - DNS
  # 80,443 - http, https
  # 1080 - xray/v2ray proxy port
  # 6443 - Kubernetes API Server
  # 10250 - Kubelet metrics
  # 7400 - frpc admin port
  networking.firewall.allowedTCPPorts = [
    80
    443
    1080
    6443
    10250
    7400
  ];
  networking.firewall.allowedUDPPorts = [ 51820 ];
  # networking.firewall.allowedTCPPortRanges = { from = 4000; to = 4007; };
  # networking.firewall.allowedUDPPortRanges = { from = 4000; to = 4007; };
  networking.firewall.trustedInterfaces = [
    "cni0"
    "flannel.1"
  ];

  # Add flux CLI and jq for backup scripts
  # flux: for GitOps operations
  # jq: for JSON parsing in backup scripts
  environment.systemPackages = with pkgs; [
    k3s
    fluxcd
    jq
  ];
}
