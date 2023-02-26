{ pkgs, machineConfig, ...}:
let
  symlinkPath = "/var/lib/rancher/k3s/server/manifests/07-filebrowser.yaml";
  wgEasyHelmChart = pkgs.writeTextFile {
    name = "filebrowser.yaml";
    text = builtins.replaceStrings
      [ ]
      [ ]
      (builtins.readFile ./filebrowser.yaml);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "k3s-filebrowser";
    buildCommand = ''
      install -v -D -p -m600 ${wgEasyHelmChart} $out/filebrowser.yaml
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /filebrowser.yaml}"
