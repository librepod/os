{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/08-hajimari.yaml";
  helmChart = pkgs.writeTextFile {
    name = "hajimari.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile ./hajimari.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-hajimari";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/hajimari.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /hajimari.yaml}"
