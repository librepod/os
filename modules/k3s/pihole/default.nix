{ pkgs, machineConfig, ...}:
let
  hostIP = machineConfig.hostIP;
  imageRepository = machineConfig.pihole.imageRepository;
  unboundImageRepository = machineConfig.pihole.unboundImageRepository;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/05-pihole.yaml";
  helmChart = pkgs.writeTextFile {
    name = "pihole.yaml";
    text = builtins.replaceStrings
      [ "{{hostIP}}" "{{imageRepository}}" "{{unboundImageRepository}}" ]
      [ hostIP imageRepository unboundImageRepository ]
      (builtins.readFile ./pihole.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-pihole";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/pihole.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /pihole.yaml}"
