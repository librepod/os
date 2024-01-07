{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/00-argocd.yaml";
  helmChart = pkgs.writeTextFile {
    name = "argocd.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile ./argocd.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-argocd";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/argocd.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /argocd.yaml}"
