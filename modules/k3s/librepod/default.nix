{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/00-librepod-ns.yaml";
  helmChart = pkgs.writeTextFile {
    name = "librepod.yaml";
    text = builtins.replaceStrings
      [ ]
      [ ]
      (builtins.readFile ./librepod.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-librepod";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/librepod.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /librepod.yaml}"
