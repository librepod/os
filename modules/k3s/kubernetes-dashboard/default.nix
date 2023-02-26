{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/04-kubernetes-dashboard.yaml";
  helmChart = pkgs.writeTextFile {
    name = "kubernetes-dashboard.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile ./kubernetes-dashboard.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-kubernetes-dashboard";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/kubernetes-dashboard.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /kubernetes-dashboard.yaml}"
