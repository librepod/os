{ config, lib, pkgs, ... }@args:
let
  machineConfig = {
    hostName = lib.mkDefault "librepod";
    hostIP = args.hostIP or lib.strings.fileContents ../../machine-ip.txt;
    networkInterfaceName = "enp0s3";
    domain = "libre.pod";
    k3sExtraFlags = "--disable local-storage";
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
  ];

  networking.hostName = machineConfig.hostName;
  networking.interfaces."${machineConfig.networkInterfaceName}".useDHCP = true;
}
