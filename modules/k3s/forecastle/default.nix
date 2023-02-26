{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/08-forecastle.yaml";
  helmChart = pkgs.writeTextFile {
    name = "forecastle.yaml";
    text = builtins.replaceStrings
      [ "{{domain}}" ]
      [ domain ]
      (builtins.readFile ./forecastle.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-forecastle";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/forecastle.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /forecastle.yaml}"
