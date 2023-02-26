{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/00-traefik.yaml";
  helmChart = pkgs.writeTextFile {
    name = "traefik.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile ./traefik.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-traefik";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/traefik.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /traefik.yaml}"
