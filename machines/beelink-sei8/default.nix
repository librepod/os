{ config, lib, pkgs, ... }@args:
let
  machineConfig = {
    hostName = "librepod";
    # hostIP = args.hostIP or lib.strings.fileContents ../../machine-ip.txt;
    hostIP = lib.strings.fileContents ../../machine-ip.txt;
    networkInterfaceName = "enp1s0";
    domain = "libre.pod";
    # Disabling local-storage since we are going to use nfs and nfs-provisioner
    # Disabling traefik since we are going to deploy and configure it with argocd
    k3sExtraFlags = "--disable=local-storage --disable=traefik";
    argocd.enable = true;
  };
in
{
  imports = [
    ./boot.nix
    (import ../../modules/common { inherit config pkgs machineConfig; })
    ../../modules/networking
    ../../modules/nix
    ../../modules/ssh
    ../../modules/users
    ../../modules/nfs
    (import ../../modules/k3s { inherit config pkgs lib machineConfig; })
    ../../modules/frpc
  ];

  services.frpc.enable = true;
  services.openssh = {
    # Banner has been generated here:
    # http://www.patorjk.com/software/taag/#p=display&f=Small&t=Beelink%20SEi8
    banner = ''
  ___          _ _      _     ___ ___ _ ___ 
 | _ ) ___ ___| (_)_ _ | |__ / __| __(_| _ )
 | _ \/ -_) -_) | | ' \| / / \__ \ _|| / _ \
 |___/\___\___|_|_|_||_|_\_\ |___/___|_\___/

    '';
  };

  networking.hostName = machineConfig.hostName;
  networking.interfaces."${machineConfig.networkInterfaceName}".useDHCP = true;
}
