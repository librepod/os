let
  pkgs = import (builtins.fetchGit {
    name = "nixos-22.11";
    url = "https://github.com/nixos/nixpkgs";
    # Commit hash for nixos-22.05 as of 2022-12-29
    # `git ls-remote https://github.com/nixos/nixpkgs release-22.11`
    ref = "refs/heads/release-22.11";
    rev = "e19f25b587f15871d26442cfa1abe4418a815d7d";
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
    hostIP = "192.168.2.167";
    # hostIP = "192.168.43.92";
  in {
    imports = [ (import ./machines/virtualbox-vm { inherit config lib pkgs hostIP; }) ];
    deployment = {
      tags = [ "local" ];
      targetHost = hostIP;
      targetUser = "root";
    };
  };
}
