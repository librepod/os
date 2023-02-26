{ pkgs, machineConfig, ...}:
let
  hostIP = machineConfig.hostIP;
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/01-nfs-provisioner.yaml";
  helmChart = pkgs.writeTextFile {
    name = "nfs-provisioner.yaml";
    text = builtins.replaceStrings
      [ "{{hostIP}}" ]
      [ hostIP ]
      (builtins.readFile ./nfs-provisioner.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-nfs-provisioner";
    buildCommand = ''
      install -v -D -p -m600 ${helmChart} $out/nfs-provisioner.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /nfs-provisioner.yaml}"
