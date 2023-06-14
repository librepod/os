{ config, lib, pkgs, ... }@args:
let
  machineConfig = {
    hostName = "librepod";
    # hostIP = args.hostIP or lib.strings.fileContents ../../machine-ip.txt;
    hostIP = lib.strings.fileContents ../../machine-ip.txt;
    networkInterfaceName = "enp1s0";
    domain = "libre.pod";
    k3sExtraFlags = [ ];
    pihole = {
      enable = true;
      imageRepository = "pihole/pihole";
      unboundImageRepository = "mvance/unbound";
    };
    wgEasy.enable = true;
    nfsProvisioner.enable = true;
    kubernetesDashboard.enable = false;
    kubeapps.enable = false;
    hajimari.enable = false;
    forecastle.enable = true;
    filebrowser.enable = true;
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

  networking.hostName = machineConfig.hostName;
  networking.interfaces."${machineConfig.networkInterfaceName}".useDHCP = true;
}
