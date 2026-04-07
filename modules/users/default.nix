{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.librepod.users;
in
{
  options.librepod.users = {
    root = {
      hashedPassword = lib.mkOption {
        type = lib.types.str;
        description = "Root user hashed password (generate with `mkpasswd -m sha-512`)";
      };
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys for root";
      };
    };
    librepod = {
      hashedPassword = lib.mkOption {
        type = lib.types.str;
        description = "Normal user hashed password (generate with `mkpasswd -m sha-512`)";
      };
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys for the normal user";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "wheel" ];
        description = "Extra groups for the normal user";
      };
    };
  };

  config = {
    users = {
      defaultUserShell = pkgs.zsh;
      mutableUsers = false;
      users.root = {
        hashedPassword = cfg.root.hashedPassword;
        openssh.authorizedKeys.keys = cfg.root.sshKeys;
      };
      users.librepod = {
        isNormalUser = true;
        hashedPassword = cfg.librepod.hashedPassword;
        extraGroups = cfg.librepod.extraGroups;
        openssh.authorizedKeys.keys = cfg.librepod.sshKeys;
      };
    };
  };
}
