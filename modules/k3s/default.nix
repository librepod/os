{
  config,
  pkgs,
  lib,
  ...
}:
let
  # k3s's helm-controller (klipper) only (re)runs a chart's install/upgrade Job when the
  # HelmChart's configHash differs from the hash recorded on the deployed release. The
  # configHash covers the entire Job pod template, and nixpkgs injects `spec.version` into
  # the pod's VERSION env — so the version is part of that hash.
  #
  # Problem: nixpkgs' services.k3s.autoDeployCharts generates a *version-less* `spec.chart`
  # (e.g. .../static/charts/flux-operator.tgz) and never sets spec.version; the version is
  # used only to fetch the tarball at build time. Bumping a chart's version therefore changes
  # neither spec.chart nor the pod template, so the configHash is unchanged and klipper never
  # upgrades the in-cluster release — it stays frozen at whatever was first installed.
  #
  # Fix: mirror each chart's `version` into the HelmChart CR's spec.version via the
  # `extraFieldDefinitions` escape hatch nixpkgs provides. This makes the version part of the
  # configHash, so version bumps are deployed automatically on the next k3s reconcile.
  # `helm` ignores --version for packaged charts, so this does not change what is installed.
  # Refs:
  #   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/cluster/rancher/default.nix
  #   https://github.com/rancher/helm-controller (pkg/controllers/chart/chart.go: hashObjects)
  mkAutoDeployChart =
    chart:
    let
      # chart files are NixOS submodule modules (functions); evaluate them to a plain config
      # attrset so we can inject a field before they reach the autoDeployCharts option.
      c = if lib.isFunction chart then chart { inherit lib pkgs; } else chart;
    in
    if c ? version then
      lib.recursiveUpdate c {
        extraFieldDefinitions.spec.version = c.version;
      }
    else
      c;
in
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
      flux-operator = mkAutoDeployChart (import ./charts/flux-operator.nix);
      flux-instance = mkAutoDeployChart (import ./charts/flux-instance.nix);
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
