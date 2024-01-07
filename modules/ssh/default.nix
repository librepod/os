{ pkgs, config, ... }:

{
  services.openssh = {
    enable = true;
    banner = ''
 _     _  _               ___          _
| |   (_)| |__  _ _  ___ | _ \ ___  __| |
| |__ | ||  _ \| '_|/ -_)|  _// _ \/ _` |
|____||_||____/|_|  \___||_|  \___/\__/_|

    '';
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
    extraConfig = ''
      AuthenticationMethods publickey password
    '';
  };
}
