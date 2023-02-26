{ pkgs, machineConfig, ...}:
let
  domain = machineConfig.domain;
  hostIP = machineConfig.hostIP;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/06-wg-easy.yaml";
  wgEasyHelmChart = pkgs.writeTextFile {
    name = "wg-easy.yaml";
    text = builtins.replaceStrings
      [ "{{hostIP}}" ]
      [ hostIP ]
      (builtins.readFile ./wg-easy.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-wg-easy";
    buildCommand = ''
      install -v -D -p -m600 ${wgEasyHelmChart} $out/wg-easy.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /wg-easy.yaml}"
