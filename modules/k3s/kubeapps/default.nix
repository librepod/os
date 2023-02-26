{ pkgs, machineConfig, ... }:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/07-kubeapps.yaml";
  helmChart = pkgs.writeTextFile {
    name = "kubeapps.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile (./. + "/${machineConfig.hostName}-kubeapps.yaml"));
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-kubeapps";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/kubeapps.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /kubeapps.yaml}"
