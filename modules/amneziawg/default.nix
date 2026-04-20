{ config, pkgs, ... }:
{
  # Load out-of-tree AmneziaWG kernel module
  boot.extraModulePackages = [ config.boot.kernelPackages.amneziawg ];
  boot.kernelModules = [ "amneziawg" ];

  # Install CLI tools (awg command)
  environment.systemPackages = [ pkgs.amneziawg-tools ];
}
