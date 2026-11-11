{ lib, pkgs, ... }:

let
  banner = pkgs.writeText "ssh_banner" ''
     _     _  _               ___          _
    | |   (_)| |__  _ _  ___ | _ \ ___  __| |
    | |__ | ||  _ \| '_|/ -_)|  _// _ \/ _` |
    |____||_||____/|_|  \___||_|  \___/\__/_|

  '';
in
{
  services.openssh = {
    enable = true;
    settings = {
      Banner = lib.mkDefault "${banner}";
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      # Key or password; modules/identity requires both.
      AuthenticationMethods = lib.mkDefault "publickey password";
    };
  };
}
