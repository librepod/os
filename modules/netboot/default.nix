{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  cfg = config.librepod.netboot;

  # Build a custom NixOS netboot installer image.
  # Uses the standard NixOS netboot-minimal profile with overrides for
  # faster squashfs compression, serial console, and SSH access.
  netbootInstaller = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      (modulesPath + "/installer/netboot/netboot-minimal.nix")

      {
        # Faster compression for quicker image builds (default is zstd level 19)
        netboot.squashfsCompression = "zstd -Xcompression-level 6";

        # Serial console for headless devices
        boot.kernelParams = [ "console=ttyS0,115200" ];

        # Inject SSH keys into the installer for remote access
        users.users.root.openssh.authorizedKeys.keys = cfg.sshKeys;

        # Auto-login as root on the installer console (useful for headless setups)
        services.getty.autologinUser = lib.mkIf cfg.autoLogin (lib.mkForce "root");

        # Enable SSH in the installer
        services.openssh.enable = true;

        environment.systemPackages =
          with pkgs;
          [
            disko
            pciutils
            usbutils
            ethtool
            iperf3
            vim
          ]
          ++ cfg.extraPackages;

        system.stateVersion = config.system.nixos.release;
      }
    ];
  };
in
{
  options.librepod.netboot = {
    enable = lib.mkEnableOption "Pixiecore network boot server";

    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = (config.librepod.users or { }).root.sshKeys or [ ];
      defaultText = lib.literalExpression "config.librepod.users.root.sshKeys or []";
      description = "SSH public keys to bake into the netboot installer image. Defaults to root's keys from librepod.users.";
    };

    autoLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Auto-login as root on the installer console (useful for headless setups)";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages to include in the installer image";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.1.1";
      description = "IPv4 address to listen on for multi-homed hosts. null means all interfaces (0.0.0.0).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Pixiecore CLI for debugging
    environment.systemPackages = map lib.lowPrio [ pkgs.pixiecore ];

    # Build the netboot installer image
    system.build.librepod-netboot = netbootInstaller;

    # Pixiecore systemd service
    systemd.services.pixiecore = {
      description = "Pixiecore network boot server";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart =
          let
            build = netbootInstaller.config.system.build;
          in
          ''
            ${pkgs.pixiecore}/bin/pixiecore \
              boot ${build.kernel}/bzImage ${build.netbootRamdisk}/initrd \
              --cmdline "init=${build.toplevel}/init loglevel=4 console=ttyS0,115200" \
              --debug \
              --dhcp-no-bind \
              --port 64172 \
              --status-port 64172 \
              ${lib.optionalString (cfg.listenAddress != null) "--listen-addr ${cfg.listenAddress}"} \
          '';
      };
    };

    # Firewall ports for PXE boot:
    #   UDP 67    - DHCP (snooped by --dhcp-no-bind)
    #   UDP 69    - TFTP
    #   UDP 4011  - PXE
    #   TCP 64172 - Pixiecore HTTP (kernel + initrd serving + status)
    networking.firewall.allowedUDPPorts = [
      67
      69
      4011
    ];
    networking.firewall.allowedTCPPorts = [ 64172 ];
  };
}
