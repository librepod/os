{ lib, ... }:
let
  pkgs = import (builtins.fetchGit {
    name = "nixos-22.11";
    url = "https://github.com/nixos/nixpkgs";
    # Commit hash for nixos-22.11 as of 2023-03-08
    # `git ls-remote https://github.com/nixos/nixpkgs release-22.11`
    ref = "refs/heads/release-22.11";
    rev = "d15c868c8b73bae604a8e2e5c7b4bb29fdeedbd8";
  }) {};
  machine = lib.strings.fileContents ./machine.txt;
  hostIP = lib.strings.fileContents ./machine-ip.txt;
in
{
  imports = [
    (./. + "/machines/${machine}")
  ];
}
