let
  pkgs = import (builtins.fetchGit {
    name = "nixos-23.05";
    url = "https://github.com/nixos/nixpkgs";
    # Commit hash for tag 23.05
    # `git ls-remote https://github.com/nixos/nixpkgs 23.05`
    ref = "refs/tags/23.05";
    rev = "90d94ea32eed9991e2b8c6a761ccd8145935c57c";
  }) {};
in
{
  network =  {
    inherit pkgs;
    description = "LibrePod hosts";
    ordering = {
      tags = [ "local" ];
    };
  };

  "beelink-sei8" = { config, pkgs, lib, ... }: let
    hostIP = "192.168.2.167";
  in {
    imports = [ (import ./machines/beelink-sei8 { inherit config lib pkgs hostIP; }) ];
    deployment = {
      tags = [ "local" ];
      targetHost = hostIP;
      targetUser = "root";
    };
  };

  "virtualbox-vm" = { config, pkgs, lib, ... }: let
    # hostIP = "192.168.2.167";
    hostIP = "192.168.43.92";
  in {
    imports = [ (import ./machines/virtualbox-vm { inherit config lib pkgs hostIP; }) ];
    deployment = {
      tags = [ "local" ];
      targetHost = hostIP;
      targetUser = "root";
    };
  };
}
