# Stub NixOS configuration that imports all librepod-os modules.
# Used by the eval-modules check to catch syntax, import, and option errors.
#
# NOTE: This file is intentionally NOT a module itself -- it is a NixOS
# configuration attrset passed directly to nixpkgs.lib.nixosSystem.
# It therefore lives under checks/ (not modules/) and must NOT contain
# top-level `options` or `config` keys -- only NixOS configuration values.

{ pkgs, lib, ... }:

{
  # ── All 13 modules ──
  imports = [
    ../modules/casdoor
    ../modules/common
    ../modules/disko
    ../modules/duplicati
    ../modules/frpc
    ../modules/gitolite
    ../modules/gobackup
    ../modules/k3s
    ../modules/networking
    ../modules/nfs
    ../modules/nix
    ../modules/ssh
    ../modules/users
  ];

  # ── Option-based modules (need enable flags + required options) ──

  # frpc (enable flag + required string options)
  librepod.frpc = {
    enable = true;
    serverAddr = "127.0.0.1";
    auth.token = "stub-token";
  };

  # users (required hashedPassword strings)
  librepod.users = {
    root.hashedPassword = "$6$rounds=4096$stub$stubhash";
    librepod.hashedPassword = "$6$rounds=4096$stub$stubhash";
  };

  # gobackup (enable flag, package.nix exercised via import chain)
  services.gobackup = {
    enable = true;
  };

  # ── Required stubs for modules that reference system state ──

  # Provide a boot.loader so NixOS evaluation doesn't warn about missing bootloader
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # common module already sets system.stateVersion = "21.11", no override needed
}
