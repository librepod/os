{ config, pkgs, ...}:
let
  symlinkPath = "/etc/frp/frpc.ini";
  frpcConfig = pkgs.writeTextFile {
    name = "frpc.ini";
    text = builtins.replaceStrings
      [ "{{relayServer}}" "{{authToken}}" ]
      [ config.services.frpc.relayServer config.services.frpc.authToken ]
      (builtins.readFile ./frpc.ini);
  };
  der = pkgs.stdenv.mkDerivation {
    name = "frpc-config";
    buildCommand = ''
      install -v -D -p -m600 ${frpcConfig} $out/frpc.ini
    '';
  };
in "L+ ${symlinkPath} - - - - ${der + /frpc.ini}"
