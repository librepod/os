{ pkgs, lib, ... }:
let
  authorizedKeysContents = lib.strings.fileContents ../../authorized_keys;
  authorizedKeysList = builtins.split "\n" authorizedKeysContents;
  authorizedKeys = builtins.filter builtins.isString (builtins.filter (s: s != "") authorizedKeysList);
in
{
  users = {
    defaultUserShell = pkgs.zsh;
    mutableUsers = false;
    users.root = {
      password = "librepod";
      openssh.authorizedKeys.keys = authorizedKeys;
    };
    users.nixos = {
      isNormalUser = true;
      password = "pass@w0rd";
      extraGroups = [
        "wheel"
        "docker"
      ];
      openssh.authorizedKeys.keys = authorizedKeys;
    };
  };
}
