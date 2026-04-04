{ config, lib, pkgs, ... }@args:
{
  imports = [
    ./boot.nix
    (import ../../modules/common { inherit config pkgs; })
    ../../modules/networking
    ../../modules/nix
    ../../modules/ssh
    ../../modules/users
    ../../modules/nfs
    (import ../../modules/k3s { inherit config pkgs lib; })
  ];
}
