{ lib, ... }:
let
  pkgs = import (builtins.fetchGit {
    name = "nixos-23.05";
    url = "https://github.com/nixos/nixpkgs";
    # Commit hash for tag 23.05
    # `git ls-remote https://github.com/nixos/nixpkgs 23.05`
    ref = "refs/tags/23.05";
    rev = "90d94ea32eed9991e2b8c6a761ccd8145935c57c";
  }) {};
  machine = lib.strings.fileContents ./machine.txt;
  hostIP = lib.strings.fileContents ./machine-ip.txt;
in
{
  imports = [
    (./. + "/machines/${machine}")
  ];
}
